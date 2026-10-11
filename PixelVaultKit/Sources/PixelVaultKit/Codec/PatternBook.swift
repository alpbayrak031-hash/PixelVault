import Accelerate
import Foundation

/// A pattern dictionary in the three layouts the codec needs.
///
/// Patterns are stored in the file as signed bytes. Both encoder and decoder work with the
/// unit-length float form, derived by the normative rule `pattern = bytes / ‖bytes‖`
/// (single precision; an all-zero entry stays zero).
struct PatternBook: Sendable {
    static let length = PIXVFormat.patternLength

    /// Number of patterns.
    let count: Int
    /// `count × 16` stored bytes, row-major.
    let stored: [Int8]
    /// `count × 16` unit-length rows, for reconstruction.
    let patterns: [Float]
    /// `16 × count`, the same matrix transposed, for the matrix-multiply search.
    let transposed: [Float]

    static let empty = PatternBook(stored: [])

    init(stored: [Int8]) {
        precondition(stored.count % Self.length == 0)
        let count = stored.count / Self.length
        var patterns = [Float](repeating: 0, count: stored.count)
        var transposed = [Float](repeating: 0, count: stored.count)
        for row in 0..<count {
            var energy: Float = 0
            for column in 0..<Self.length {
                let value = Float(stored[row * Self.length + column])
                energy += value * value
            }
            guard energy > 0 else { continue }
            let norm = energy.squareRoot()
            for column in 0..<Self.length {
                let value = Float(stored[row * Self.length + column]) / norm
                patterns[row * Self.length + column] = value
                transposed[column * count + row] = value
            }
        }
        self.count = count
        self.stored = stored
        self.patterns = patterns
        self.transposed = transposed
    }

    /// Quantises unit-length float rows to the stored byte form.
    init(quantizing rows: [Float]) {
        self.init(stored: rows.map { Int8(max(-127, min(127, ($0 * 127).rounded()))) })
    }

    /// A book holding rows `order[0], order[1], …` of this one.
    func reordered(_ order: [Int]) -> PatternBook {
        var result = [Int8]()
        result.reserveCapacity(order.count * Self.length)
        for row in order {
            result.append(contentsOf: stored[(row * Self.length)..<((row + 1) * Self.length)])
        }
        return PatternBook(stored: result)
    }
}

/// Exhaustive nearest-pattern search on Accelerate.
///
/// Patterns are unit length and may be applied with either sign, so the best match for a
/// residual `x` is the pattern maximising `|x · p|`, and `x · p` is its least-squares gain.
/// All dot products for a batch of blocks are one matrix product, which Accelerate runs on
/// the CPU's matrix hardware; `vDSP_maxmgvi` then picks the winner per block.
enum PatternSearch {
    /// - Parameters:
    ///   - vectors: `count × 16` residuals, row-major.
    ///   - indices: receives the winning pattern per row.
    ///   - gains: receives the signed dot product with that pattern.
    static func search(vectors: UnsafePointer<Float>, count: Int, book: PatternBook,
                       indices: UnsafeMutablePointer<UInt16>, gains: UnsafeMutablePointer<Float>) {
        let patternCount = book.count
        guard count > 0, patternCount > 0 else { return }
        let length = PatternBook.length
        // Keep each batch's product matrix around 2 MB so it stays cache-resident.
        let batch = max(32, min(1024, (1 << 19) / patternCount))

        book.transposed.withUnsafeBufferPointer { transposed in
            let codebook = transposed.baseAddress!
            Parallel.stripes(count, grain: batch) { rows in
                let products = UnsafeMutablePointer<Float>.allocate(capacity: batch * patternCount)
                defer { products.deallocate() }
                var row = rows.lowerBound
                while row < rows.upperBound {
                    let size = min(batch, rows.upperBound - row)
                    vDSP_mmul(vectors + row * length, 1, codebook, 1, products, 1,
                              vDSP_Length(size), vDSP_Length(patternCount), vDSP_Length(length))
                    for offset in 0..<size {
                        var magnitude: Float = 0
                        var winner: vDSP_Length = 0
                        let line = products + offset * patternCount
                        vDSP_maxmgvi(line, 1, &magnitude, &winner, vDSP_Length(patternCount))
                        indices[row + offset] = UInt16(winner)
                        gains[row + offset] = line[Int(winner)]
                    }
                    row += size
                }
            }
        }
    }
}

/// Learns a gain–shape pattern dictionary from residual blocks.
///
/// This is k-means on the unit sphere with sign folding: assign each block to the pattern
/// with the largest `|x · p|`, then move each pattern to `normalise(Σ (x · p) x)` over its
/// members — one power-iteration step toward the dominant direction of the cluster, which
/// is the choice that minimises the squared error left after the best gain is applied.
enum CodebookTrainer {
    /// - Parameters:
    ///   - samples: `count × 16` training residuals.
    ///   - patternCount: dictionary size to learn; must not exceed `count`.
    /// - Returns: `patternCount × 16` unit-length rows.
    static func train(samples: [Float], count: Int, patternCount: Int, iterations: Int) -> [Float] {
        let length = PatternBook.length
        precondition(count >= patternCount && patternCount > 0)

        var energies = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<count {
                vDSP_svesq(buffer.baseAddress! + index * length, 1, &energies[index], vDSP_Length(length))
            }
        }

        // Seed with samples spread evenly through the set.
        var rows = [Float](repeating: 0, count: patternCount * length)
        for pattern in 0..<patternCount {
            let sample = pattern * count / patternCount
            copyNormalized(samples, sample: sample, energy: energies[sample], into: &rows, row: pattern)
        }

        var indices = [UInt16](repeating: 0, count: count)
        var gains = [Float](repeating: 0, count: count)
        var sums = [Float](repeating: 0, count: patternCount * length)
        var members = [Int](repeating: 0, count: patternCount)

        for _ in 0..<iterations {
            let book = PatternBook(floatRows: rows)
            samples.withUnsafeBufferPointer { buffer in
                PatternSearch.search(vectors: buffer.baseAddress!, count: count, book: book,
                                     indices: &indices, gains: &gains)
            }

            sums.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            members.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            samples.withUnsafeBufferPointer { buffer in
                sums.withUnsafeMutableBufferPointer { accumulator in
                    for index in 0..<count {
                        let pattern = Int(indices[index])
                        var gain = gains[index]
                        vDSP_vsma(buffer.baseAddress! + index * length, 1, &gain,
                                  accumulator.baseAddress! + pattern * length, 1,
                                  accumulator.baseAddress! + pattern * length, 1, vDSP_Length(length))
                        members[pattern] += 1
                    }
                }
            }

            var orphans: [Int] = []
            for pattern in 0..<patternCount {
                var energy: Float = 0
                sums.withUnsafeBufferPointer {
                    vDSP_svesq($0.baseAddress! + pattern * length, 1, &energy, vDSP_Length(length))
                }
                if members[pattern] == 0 || energy <= 1e-12 {
                    orphans.append(pattern)
                    continue
                }
                let scale = 1 / energy.squareRoot()
                for column in 0..<length {
                    rows[pattern * length + column] = sums[pattern * length + column] * scale
                }
            }

            // Patterns nothing chose are re-seeded on the blocks the dictionary explains worst.
            if !orphans.isEmpty {
                let worst = worstExplained(energies: energies, gains: gains, count: count, limit: orphans.count)
                for (pattern, sample) in zip(orphans, worst) {
                    copyNormalized(samples, sample: sample, energy: energies[sample], into: &rows, row: pattern)
                }
            }
        }
        return rows
    }

    /// The `limit` samples with the largest error left after their best pattern, worst first.
    /// A bounded min-heap keeps this linear in the sample count; orphans are usually few.
    private static func worstExplained(energies: [Float], gains: [Float], count: Int, limit: Int) -> [Int] {
        var heap: [(error: Float, sample: Int)] = []
        heap.reserveCapacity(limit)

        func siftDown(_ start: Int) {
            var parent = start
            while true {
                var smallest = parent
                let left = 2 * parent + 1, right = left + 1
                if left < heap.count, heap[left].error < heap[smallest].error { smallest = left }
                if right < heap.count, heap[right].error < heap[smallest].error { smallest = right }
                if smallest == parent { return }
                heap.swapAt(parent, smallest)
                parent = smallest
            }
        }

        for sample in 0..<count {
            let error = energies[sample] - gains[sample] * gains[sample]
            if heap.count < limit {
                heap.append((error, sample))
                var child = heap.count - 1
                while child > 0, heap[(child - 1) / 2].error > heap[child].error {
                    heap.swapAt(child, (child - 1) / 2)
                    child = (child - 1) / 2
                }
            } else if error > heap[0].error {
                heap[0] = (error, sample)
                siftDown(0)
            }
        }
        return heap.sorted { $0.error != $1.error ? $0.error > $1.error : $0.sample < $1.sample }.map(\.sample)
    }

    private static func copyNormalized(_ samples: [Float], sample: Int, energy: Float,
                                       into rows: inout [Float], row: Int) {
        let length = PatternBook.length
        if energy > 1e-12 {
            let scale = 1 / energy.squareRoot()
            for column in 0..<length {
                rows[row * length + column] = samples[sample * length + column] * scale
            }
        } else {
            // Degenerate sample: fall back to a flat pattern so the row is still unit length.
            for column in 0..<length { rows[row * length + column] = 0.25 }
        }
    }
}

extension PatternBook {
    /// A search-only book over unquantised rows, used while training.
    fileprivate init(floatRows rows: [Float]) {
        let count = rows.count / Self.length
        var transposed = [Float](repeating: 0, count: rows.count)
        for row in 0..<count {
            for column in 0..<Self.length {
                transposed[column * count + row] = rows[row * Self.length + column]
            }
        }
        self.count = count
        self.stored = []
        self.patterns = rows
        self.transposed = transposed
    }
}
