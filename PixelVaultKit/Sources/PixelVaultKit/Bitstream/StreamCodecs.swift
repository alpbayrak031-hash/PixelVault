import Foundation

/// The lowest-resolution plane of each pyramid, coded losslessly (after quantisation) with
/// a median-edge predictor and context-modelled residuals — the scheme JPEG-LS made standard.
enum BaseLayerCodec {
    private static let scaleBits = UInt32(ContextTables.scaleBits)
    private static let mask: UInt32 = (1 << scaleBits) - 1

    /// Predicts sample `(x, y)` from its causal neighbours and classifies the local activity.
    @inline(__always)
    private static func predict(_ samples: UnsafePointer<UInt8>, x: Int, y: Int, width: Int,
                                origin: Int) -> (prediction: Int, context: Int) {
        let position = y * width + x
        let left: Int, up: Int, upLeft: Int
        if y > 0 && x > 0 {
            left = Int(samples[position - 1])
            up = Int(samples[position - width])
            upLeft = Int(samples[position - width - 1])
        } else if x > 0 {
            left = Int(samples[position - 1]); up = left; upLeft = left
        } else if y > 0 {
            up = Int(samples[position - width]); left = up; upLeft = up
        } else {
            left = origin; up = origin; upLeft = origin
        }

        let low = min(left, up), high = max(left, up)
        let prediction = upLeft >= high ? low : (upLeft <= low ? high : left + up - upLeft)

        // Buckets 0, 1–2, 3–6, 7–14, 15–30, 31+.
        let activity = abs(left - upLeft) + abs(up - upLeft) + 1
        let context = min(PIXVFormat.baseContexts - 1, Int.bitWidth - activity.leadingZeroBitCount - 1)
        return (prediction, context)
    }

    /// The value predicted for the very first sample: mid-grey in quantised units.
    static func origin(step: Int) -> Int {
        (128 + step / 2) / step
    }

    static func maxLevel(step: Int) -> Int {
        (255 + step / 2) / step
    }

    /// `levels` holds quantised samples. Output: context tables followed by the rANS bytes.
    static func encode(levels: Plane, step: Int) -> [UInt8] {
        let width = levels.width, height = levels.height
        let origin = origin(step: step)
        var contexts = [UInt8].uninitialized(width * height)
        var residuals = [UInt16].uninitialized(width * height)
        var counts = Array(repeating: [Int](repeating: 0, count: PIXVFormat.baseAlphabet), count: PIXVFormat.baseContexts)
        var escapes = 0

        levels.data.withUnsafeBufferPointer { samples in
            for y in 0..<height {
                for x in 0..<width {
                    let (prediction, context) = predict(samples.baseAddress!, x: x, y: y, width: width, origin: origin)
                    let error = Int(samples[y * width + x]) - prediction
                    let folded = error >= 0 ? 2 * error : -2 * error - 1
                    contexts[y * width + x] = UInt8(context)
                    residuals[y * width + x] = UInt16(folded)
                    let symbol = min(folded, PIXVFormat.baseEscape)
                    counts[context][symbol] += 1
                    if symbol == PIXVFormat.baseEscape { escapes += 1 }
                }
            }
        }

        let tables = ContextTables(counts: counts, alphabetSize: PIXVFormat.baseAlphabet)
        var tokens = [UInt32]()
        tokens.reserveCapacity(width * height + escapes)
        for position in 0..<(width * height) {
            let folded = Int(residuals[position])
            let symbol = min(folded, PIXVFormat.baseEscape)
            tokens.append(tables.token(context: Int(contexts[position]), symbol: symbol))
            if symbol == PIXVFormat.baseEscape {
                tokens.append(RANS.rawBitsToken(UInt32(folded), bitCount: PIXVFormat.baseEscapeBits,
                                                scaleBits: ContextTables.scaleBits))
            }
        }

        var writer = ByteWriter()
        tables.write(to: &writer)
        writer.append(tokens.withUnsafeBufferPointer { RANS.encode(tokens: $0, scaleBits: ContextTables.scaleBits) })
        return writer.bytes
    }

    static func decode(_ bytes: [UInt8], range: Range<Int>, width: Int, height: Int, step: Int) throws -> Plane {
        var reader = ByteReader(bytes, range: range)
        let tables = try ContextTables(reading: &reader, contextCount: PIXVFormat.baseContexts,
                                       alphabetSize: PIXVFormat.baseAlphabet).makeDecoder()
        let origin = origin(step: step)
        let maxLevel = maxLevel(step: step)
        var plane = Plane(uninitializedWidth: width, height: height)
        var outOfRange = false

        try bytes.withUnsafeBufferPointer { buffer in
            var decoder = try RansDecoder(UnsafeBufferPointer(rebasing: buffer[reader.offset..<range.upperBound]))
            plane.data.withUnsafeMutableBufferPointer { samples in
                tables.slotToSymbol.withUnsafeBufferPointer { slots in
                    for y in 0..<height {
                        for x in 0..<width {
                            let (prediction, context) = predict(UnsafePointer(samples.baseAddress!), x: x, y: y,
                                                                width: width, origin: origin)
                            let slot = decoder.peek(mask: mask)
                            let symbol = Int(slots[context << Int(scaleBits) | Int(slot)])
                            let entry = context * PIXVFormat.baseAlphabet + symbol
                            decoder.advance(start: UInt32(tables.start[entry]), frequency: UInt32(tables.frequency[entry]),
                                            scaleBits: scaleBits, mask: mask)
                            var folded = symbol
                            if symbol == PIXVFormat.baseEscape {
                                folded = Int(decoder.rawBits(PIXVFormat.baseEscapeBits, scaleBits: scaleBits, mask: mask))
                            }
                            let error = folded & 1 == 0 ? folded >> 1 : -((folded + 1) >> 1)
                            let value = prediction + error
                            if value < 0 || value > maxLevel { outOfRange = true }
                            samples[y * width + x] = UInt8(max(0, min(maxLevel, value)))
                        }
                    }
                }
            }
            try decoder.finish()
        }
        guard !outOfRange else { throw PIXVError.corrupt("base layer sample out of range") }
        return plane
    }
}

/// Per-block stage counts, coded against the two causal neighbours and the block above
/// in the pyramid — detail clusters, so those three predict it well.
enum ModeCodec {
    static let contextCount = 18
    private static let scaleBits = UInt32(ContextTables.scaleBits)
    private static let mask: UInt32 = (1 << scaleBits) - 1

    /// The modes of the next-coarser level, whose blocks each cover 2×2 of this level's.
    struct Parent {
        let modes: [UInt8]
        let blocksWide: Int
    }

    @inline(__always)
    private static func context(_ modes: UnsafePointer<UInt8>, x: Int, y: Int, blocksWide: Int,
                                parent: UnsafePointer<UInt8>?, parentWide: Int) -> Int {
        let left = x > 0 ? min(Int(modes[y * blocksWide + x - 1]), 2) : 0
        let up = y > 0 ? min(Int(modes[(y - 1) * blocksWide + x]), 2) : 0
        var context = left * 3 + up
        if let parent, parent[(y >> 1) * parentWide + (x >> 1)] > 0 { context += 9 }
        return context
    }

    /// `alphabetSize` is the plane's stage count plus one.
    static func encode(_ coding: LevelCoding, parent: Parent?, alphabetSize: Int) -> [UInt8] {
        let blocksWide = coding.blocksWide, blocksHigh = coding.blocksHigh
        var counts = Array(repeating: [Int](repeating: 0, count: alphabetSize), count: contextCount)
        var contexts = [UInt8].uninitialized(coding.blockCount)

        func withParent<R>(_ body: (UnsafePointer<UInt8>?) -> R) -> R {
            guard let parent else { return body(nil) }
            return parent.modes.withUnsafeBufferPointer { body($0.baseAddress) }
        }

        coding.modes.withUnsafeBufferPointer { modes in
            withParent { parentModes in
                for y in 0..<blocksHigh {
                    for x in 0..<blocksWide {
                        let selected = context(modes.baseAddress!, x: x, y: y, blocksWide: blocksWide,
                                               parent: parentModes, parentWide: parent?.blocksWide ?? 0)
                        contexts[y * blocksWide + x] = UInt8(selected)
                        counts[selected][Int(modes[y * blocksWide + x])] += 1
                    }
                }
            }
        }

        let tables = ContextTables(counts: counts, alphabetSize: alphabetSize)
        var tokens = [UInt32].uninitialized(coding.blockCount)
        for block in 0..<coding.blockCount {
            tokens[block] = tables.token(context: Int(contexts[block]), symbol: Int(coding.modes[block]))
        }

        var writer = ByteWriter()
        tables.write(to: &writer)
        writer.append(tokens.withUnsafeBufferPointer { RANS.encode(tokens: $0, scaleBits: ContextTables.scaleBits) })
        return writer.bytes
    }

    static func decode(_ bytes: [UInt8], range: Range<Int>, blocksWide: Int, blocksHigh: Int,
                       parent: Parent?, alphabetSize: Int) throws -> [UInt8] {
        var reader = ByteReader(bytes, range: range)
        let tables = try ContextTables(reading: &reader, contextCount: contextCount,
                                       alphabetSize: alphabetSize).makeDecoder()
        var modes = [UInt8].uninitialized(blocksWide * blocksHigh)

        func withParent<R>(_ body: (UnsafePointer<UInt8>?) throws -> R) rethrows -> R {
            guard let parent else { return try body(nil) }
            return try parent.modes.withUnsafeBufferPointer { try body($0.baseAddress) }
        }

        try bytes.withUnsafeBufferPointer { buffer in
            var decoder = try RansDecoder(UnsafeBufferPointer(rebasing: buffer[reader.offset..<range.upperBound]))
            modes.withUnsafeMutableBufferPointer { output in
                withParent { parentModes in
                    tables.slotToSymbol.withUnsafeBufferPointer { slots in
                        for y in 0..<blocksHigh {
                            for x in 0..<blocksWide {
                                let selected = context(UnsafePointer(output.baseAddress!), x: x, y: y,
                                                       blocksWide: blocksWide, parent: parentModes,
                                                       parentWide: parent?.blocksWide ?? 0)
                                let slot = decoder.peek(mask: mask)
                                let symbol = Int(slots[selected << Int(scaleBits) | Int(slot)])
                                let entry = selected * alphabetSize + symbol
                                decoder.advance(start: UInt32(tables.start[entry]),
                                                frequency: UInt32(tables.frequency[entry]),
                                                scaleBits: scaleBits, mask: mask)
                                output[y * blocksWide + x] = UInt8(symbol)
                            }
                        }
                    }
                }
            }
            try decoder.finish()
        }
        return modes
    }
}

/// Maps a level's per-block pattern data to and from the flat symbol runs that are entropy coded.
/// A stage's run lists, in raster order, every block whose mode exceeds that stage.
enum StageSymbols {
    /// Gain `g ∈ ±[1, 128]` → `(|g| − 1)·2 + (g < 0 ? 1 : 0)`.
    @inline(__always)
    static func gainSymbol(_ gain: Int16) -> UInt16 {
        let magnitude = UInt16(abs(Int(gain)) - 1)
        return magnitude << 1 | (gain < 0 ? 1 : 0)
    }

    @inline(__always)
    static func gain(fromSymbol symbol: UInt16) -> Int16 {
        let magnitude = Int16(symbol >> 1) + 1
        return symbol & 1 == 0 ? magnitude : -magnitude
    }

    static func flatten(_ coding: LevelCoding, stage: Int) -> (indices: [UInt16], gains: [UInt16]) {
        let base = stage * coding.blockCount
        var indices = [UInt16]()
        var gains = [UInt16]()
        let count = coding.symbolCount(stage: stage)
        indices.reserveCapacity(count)
        gains.reserveCapacity(count)
        for block in 0..<coding.blockCount where coding.modes[block] > stage {
            indices.append(coding.indices[base + block])
            gains.append(gainSymbol(coding.gains[base + block]))
        }
        return (indices, gains)
    }

    /// Inverse of `flatten`. `indices` and `gains` must hold exactly `symbolCount(stage:)` entries.
    static func scatter(indices: [UInt16], gains: [UInt16], into coding: inout LevelCoding, stage: Int) {
        let base = stage * coding.blockCount
        var cursor = 0
        for block in 0..<coding.blockCount where coding.modes[block] > stage {
            coding.indices[base + block] = indices[cursor]
            coding.gains[base + block] = gain(fromSymbol: gains[cursor])
            cursor += 1
        }
    }
}
