import Accelerate
import Foundation

/// How one pyramid level of one plane is coded: per 4×4 block, how many patterns are
/// stacked on the prediction (`modes`), and for each stage which pattern and what gain.
struct LevelCoding: Sendable {
    let blocksWide: Int
    let blocksHigh: Int
    let stages: Int
    /// Number of pattern stages applied to each block; 0 means "prediction only".
    var modes: [UInt8]
    /// `[stage * blockCount + block]`, meaningful where `modes[block] > stage`.
    var indices: [UInt16]
    /// Quantised gains in the same layout; never zero where meaningful.
    var gains: [Int16]

    var blockCount: Int { blocksWide * blocksHigh }

    init(blocksWide: Int, blocksHigh: Int, stages: Int) {
        self.blocksWide = blocksWide
        self.blocksHigh = blocksHigh
        self.stages = stages
        let count = blocksWide * blocksHigh
        modes = [UInt8](repeating: 0, count: count)
        indices = [UInt16](repeating: 0, count: count * stages)
        gains = [Int16](repeating: 0, count: count * stages)
    }

    /// Number of blocks that use at least `stage + 1` patterns.
    func symbolCount(stage: Int) -> Int {
        modes.reduce(0) { $0 + ($1 > stage ? 1 : 0) }
    }
}

enum LevelCodec {
    private static let blockSize = PIXVFormat.blockSize
    private static let length = PIXVFormat.patternLength
    private static let rowBytes = PIXVFormat.patternLength * MemoryLayout<Float>.stride

    // MARK: Block access

    @inline(__always)
    private static func loadBlock(_ plane: UnsafePointer<UInt8>, stride: Int) -> SIMD16<Float> {
        let raw = UnsafeRawPointer(plane)
        let rows = SIMD4<UInt32>(
            raw.loadUnaligned(as: UInt32.self),
            raw.loadUnaligned(fromByteOffset: stride, as: UInt32.self),
            raw.loadUnaligned(fromByteOffset: 2 * stride, as: UInt32.self),
            raw.loadUnaligned(fromByteOffset: 3 * stride, as: UInt32.self))
        return SIMD16<Float>(unsafeBitCast(rows, to: SIMD16<UInt8>.self))
    }

    @inline(__always)
    private static func storeBlock(_ value: SIMD16<Float>, to plane: UnsafeMutablePointer<UInt8>, stride: Int) {
        let clamped = value.clamped(lowerBound: .zero, upperBound: SIMD16(repeating: 255))
        let rounded = SIMD16<Int32>(clamped + 0.5, rounding: .towardZero)
        let rows = unsafeBitCast(SIMD16<UInt8>(truncatingIfNeeded: rounded), to: SIMD4<UInt32>.self)
        let raw = UnsafeMutableRawPointer(plane)
        raw.storeBytes(of: rows[0], as: UInt32.self)
        raw.storeBytes(of: rows[1], toByteOffset: stride, as: UInt32.self)
        raw.storeBytes(of: rows[2], toByteOffset: 2 * stride, as: UInt32.self)
        raw.storeBytes(of: rows[3], toByteOffset: 3 * stride, as: UInt32.self)
    }

    /// Runs `body` with a stable pointer to each book's unit-length rows (`nil` for an empty book).
    private static func withPatternRows<R>(_ books: [PatternBook],
                                           _ body: ([UnsafeRawPointer?]) -> R) -> R {
        var pointers: [UnsafeRawPointer?] = []
        pointers.reserveCapacity(books.count)
        func descend(_ index: Int) -> R {
            if index == books.count { return body(pointers) }
            return books[index].patterns.withUnsafeBytes { bytes in
                pointers.append(bytes.baseAddress)
                return descend(index + 1)
            }
        }
        return descend(0)
    }

    // MARK: Reconstruction (normative)

    /// Applies a level's patterns to its prediction.
    ///
    /// For each block with `mode > 0`, in single precision:
    /// `v = prediction; for stage in 0..<mode { v += (gain·gainStep) · pattern }`,
    /// then `clamp(v, 0, 255)` and round half up.
    ///
    /// Callers must have validated that every referenced index is inside its book.
    static func reconstruct(prediction: Plane, coding: LevelCoding, books: [PatternBook], gainStep: Float) -> Plane {
        var result = prediction
        let width = prediction.width
        let blocksWide = coding.blocksWide
        let blockCount = coding.blockCount
        precondition(blocksWide * blockSize == width && coding.blocksHigh * blockSize == prediction.height)
        precondition(books.count >= coding.stages)

        result.data.withUnsafeMutableBufferPointer { buffer in
            let plane = buffer.baseAddress!
            coding.modes.withUnsafeBufferPointer { modes in
                coding.indices.withUnsafeBufferPointer { indices in
                    coding.gains.withUnsafeBufferPointer { gains in
                        withPatternRows(books) { rows in
                            Parallel.stripes(coding.blocksHigh, grain: 4) { blockRows in
                                for blockY in blockRows {
                                    for blockX in 0..<blocksWide {
                                        let block = blockY * blocksWide + blockX
                                        let mode = Int(modes[block])
                                        if mode == 0 { continue }
                                        let origin = plane + blockY * blockSize * width + blockX * blockSize
                                        var value = loadBlock(origin, stride: width)
                                        for stage in 0..<mode {
                                            let slot = stage * blockCount + block
                                            let gain = Float(gains[slot]) * gainStep
                                            let pattern = rows[stage]!.loadUnaligned(
                                                fromByteOffset: Int(indices[slot]) * rowBytes, as: SIMD16<Float>.self)
                                            value += gain * pattern
                                        }
                                        storeBlock(value, to: origin, stride: width)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    // MARK: Encoding

    /// Chooses patterns for one level.
    ///
    /// A block is left as prediction-only when its squared error is already within
    /// `threshold` (mean squared error per sample). Otherwise patterns are stacked, each
    /// chosen against what the previous stages left behind, until the block meets the
    /// threshold, the best gain quantises to zero, or `books` runs out.
    static func encode(target: Plane, prediction: Plane, books: [PatternBook], gainStep: Float,
                       threshold: Float, acceptance: Float) -> LevelCoding {
        let width = target.width
        let blocksWide = width / blockSize, blocksHigh = target.height / blockSize
        let stages = books.count
        var coding = LevelCoding(blocksWide: blocksWide, blocksHigh: blocksHigh, stages: stages)
        let blockCount = coding.blockCount
        let limit = threshold * Float(length)
        let worthwhile = acceptance * limit
        guard stages > 0 else { return coding }

        // Pass 1: which blocks need patterns, and how many per row.
        var needsPatterns = [Bool](repeating: false, count: blockCount)
        var rowStarts = [Int](repeating: 0, count: blocksHigh + 1)
        target.data.withUnsafeBufferPointer { targetBuffer in
            prediction.data.withUnsafeBufferPointer { predictionBuffer in
                needsPatterns.withUnsafeMutableBufferPointer { flags in
                    rowStarts.withUnsafeMutableBufferPointer { counts in
                        Parallel.stripes(blocksHigh, grain: 4) { rows in
                            for blockY in rows {
                                var count = 0
                                for blockX in 0..<blocksWide {
                                    let offset = blockY * blockSize * width + blockX * blockSize
                                    let residual = loadBlock(targetBuffer.baseAddress! + offset, stride: width)
                                        - loadBlock(predictionBuffer.baseAddress! + offset, stride: width)
                                    if (residual * residual).sum() > limit {
                                        flags[blockY * blocksWide + blockX] = true
                                        count += 1
                                    }
                                }
                                counts[blockY + 1] = count
                            }
                        }
                    }
                }
            }
        }
        for row in 0..<blocksHigh { rowStarts[row + 1] += rowStarts[row] }
        var active = rowStarts[blocksHigh]
        guard active > 0 else { return coding }

        // Pass 2: gather the residuals of those blocks into one contiguous matrix.
        var residuals = [Float].uninitialized(active * length)
        var blockOf = [Int32].uninitialized(active)
        target.data.withUnsafeBufferPointer { targetBuffer in
            prediction.data.withUnsafeBufferPointer { predictionBuffer in
                needsPatterns.withUnsafeBufferPointer { flags in
                    rowStarts.withUnsafeBufferPointer { starts in
                        residuals.withUnsafeMutableBytes { matrix in
                            blockOf.withUnsafeMutableBufferPointer { owners in
                                Parallel.stripes(blocksHigh, grain: 4) { rows in
                                    for blockY in rows {
                                        var slot = starts[blockY]
                                        for blockX in 0..<blocksWide where flags[blockY * blocksWide + blockX] {
                                            let offset = blockY * blockSize * width + blockX * blockSize
                                            let residual = loadBlock(targetBuffer.baseAddress! + offset, stride: width)
                                                - loadBlock(predictionBuffer.baseAddress! + offset, stride: width)
                                            matrix.storeBytes(of: residual, toByteOffset: slot * rowBytes,
                                                              as: SIMD16<Float>.self)
                                            owners[slot] = Int32(blockY * blocksWide + blockX)
                                            slot += 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        var winners = [UInt16].uninitialized(active)
        var dots = [Float].uninitialized(active)
        var carriesOn = [Bool].uninitialized(active)
        let maxGain = Float(PIXVFormat.maxGain)

        for stage in 0..<stages {
            let book = books[stage]
            if book.count == 0 || active == 0 { break }
            let isLastStage = stage == stages - 1
            let rowCount = active

            residuals.withUnsafeBufferPointer { matrix in
                PatternSearch.search(vectors: matrix.baseAddress!, count: rowCount, book: book,
                                     indices: &winners, gains: &dots)
            }

            // Quantise each gain, subtract the pattern, and decide who needs another stage.
            residuals.withUnsafeMutableBytes { matrix in
                coding.modes.withUnsafeMutableBufferPointer { modes in
                    coding.indices.withUnsafeMutableBufferPointer { indices in
                        coding.gains.withUnsafeMutableBufferPointer { gains in
                            carriesOn.withUnsafeMutableBufferPointer { carries in
                                winners.withUnsafeBufferPointer { winners in
                                    dots.withUnsafeBufferPointer { dots in
                                        blockOf.withUnsafeBufferPointer { owners in
                                            book.patterns.withUnsafeBytes { patterns in
                                                Parallel.stripes(rowCount, grain: 2048) { range in
                                                    for row in range {
                                                        let dot = dots[row]
                                                        let quantized = max(-maxGain, min(maxGain, (dot / gainStep).rounded()))
                                                        let applied = quantized * gainStep
                                                        // Squared error this pattern removes: ‖r‖² − ‖r − ĝp‖² = ĝ(2g − ĝ).
                                                        if quantized == 0 || applied * (2 * dot - applied) < worthwhile {
                                                            carries[row] = false
                                                            continue
                                                        }
                                                        let block = Int(owners[row])
                                                        let winner = Int(winners[row])
                                                        indices[stage * blockCount + block] = UInt16(winner)
                                                        gains[stage * blockCount + block] = Int16(quantized)
                                                        modes[block] = UInt8(stage + 1)
                                                        if isLastStage {
                                                            carries[row] = false
                                                            continue
                                                        }
                                                        let pattern = patterns.loadUnaligned(
                                                            fromByteOffset: winner * rowBytes, as: SIMD16<Float>.self)
                                                        var residual = matrix.loadUnaligned(
                                                            fromByteOffset: row * rowBytes, as: SIMD16<Float>.self)
                                                        residual -= applied * pattern
                                                        matrix.storeBytes(of: residual, toByteOffset: row * rowBytes,
                                                                          as: SIMD16<Float>.self)
                                                        carries[row] = (residual * residual).sum() > limit
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if isLastStage { break }

            // Compact the survivors to the front for the next stage's search.
            var kept = 0
            residuals.withUnsafeMutableBufferPointer { matrix in
                let base = matrix.baseAddress!
                for row in 0..<rowCount where carriesOn[row] {
                    if kept != row {
                        (base + kept * length).update(from: base + row * length, count: length)
                        blockOf[kept] = blockOf[row]
                    }
                    kept += 1
                }
            }
            active = kept
        }
        return coding
    }
}
