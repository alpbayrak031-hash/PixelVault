import Foundation

/// Static range-ANS entropy coder: 32-bit state, byte-wise renormalisation.
///
/// Symbols are described by a `(start, frequency)` slice of a `2^scaleBits` probability
/// range. The encoder consumes symbols in reverse and writes its buffer back to front, so
/// the decoder reads the bytes — and recovers the symbols — strictly forward.
enum RANS {
    /// Lower bound of the normalised state interval `[2^23, 2^31)`.
    static let lowerBound: UInt32 = 1 << 23
    /// Probability resolution for small alphabets (modes, gains, base residuals).
    static let smallScaleBits = 12
    /// Probability resolution for pattern-index alphabets (up to 4096 symbols).
    static let largeScaleBits = 15

    /// Packs a symbol's probability slice into the token form `encode` consumes.
    @inline(__always)
    static func token(start: UInt32, frequency: UInt32) -> UInt32 {
        start | frequency << 16
    }

    /// Token for `bitCount` raw bits, coded as a uniform distribution.
    @inline(__always)
    static func rawBitsToken(_ value: UInt32, bitCount: Int, scaleBits: Int) -> UInt32 {
        let shift = UInt32(scaleBits - bitCount)
        return token(start: value << shift, frequency: 1 << shift)
    }

    /// Encodes `tokens` (given in forward symbol order). Returns an empty array for no symbols.
    static func encode(tokens: UnsafeBufferPointer<UInt32>, scaleBits: Int) -> [UInt8] {
        guard !tokens.isEmpty else { return [] }
        // Each symbol adds at most `scaleBits` (≤ 15) bits, so two bytes per symbol always fits.
        let capacity = tokens.count * 2 + 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        var cursor = capacity
        var state = lowerBound
        let scale = UInt32(scaleBits)
        let renormBase = (lowerBound >> scale) << 8

        var index = tokens.count
        while index > 0 {
            index -= 1
            let token = tokens[index]
            let start = token & 0xFFFF
            let frequency = token >> 16
            let limit = renormBase &* frequency
            while state >= limit {
                precondition(cursor > 4, "rANS output buffer exhausted")
                cursor -= 1
                buffer[cursor] = UInt8(truncatingIfNeeded: state)
                state >>= 8
            }
            state = ((state / frequency) << scale) &+ (state % frequency) &+ start
        }

        cursor -= 4
        buffer[cursor] = UInt8(truncatingIfNeeded: state)
        buffer[cursor + 1] = UInt8(truncatingIfNeeded: state >> 8)
        buffer[cursor + 2] = UInt8(truncatingIfNeeded: state >> 16)
        buffer[cursor + 3] = UInt8(truncatingIfNeeded: state >> 24)
        return Array(UnsafeBufferPointer(start: buffer + cursor, count: capacity - cursor))
    }
}

/// Forward rANS decoder. Reads never leave the supplied buffer; running dry is recorded
/// and reported by `finish()` instead of trapping.
struct RansDecoder {
    private var state: UInt32
    private var cursor: UnsafePointer<UInt8>
    private let end: UnsafePointer<UInt8>
    private var overrun = false

    init(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        guard bytes.count >= 4, let base = bytes.baseAddress else { throw PIXVError.truncated }
        state = UInt32(base[0]) | UInt32(base[1]) << 8 | UInt32(base[2]) << 16 | UInt32(base[3]) << 24
        cursor = base + 4
        end = base + bytes.count
    }

    /// The slot of the probability range the next symbol falls in.
    @inline(__always)
    func peek(mask: UInt32) -> UInt32 {
        state & mask
    }

    @inline(__always)
    mutating func advance(start: UInt32, frequency: UInt32, scaleBits: UInt32, mask: UInt32) {
        state = frequency &* (state >> scaleBits) &+ (state & mask) &- start
        while state < RANS.lowerBound {
            if cursor < end {
                state = (state << 8) | UInt32(cursor.pointee)
                cursor += 1
            } else {
                // Corrupt input: park on a valid state so decoding terminates, and fail in `finish()`.
                overrun = true
                state = RANS.lowerBound
            }
        }
    }

    @inline(__always)
    mutating func rawBits(_ bitCount: Int, scaleBits: UInt32, mask: UInt32) -> UInt32 {
        let shift = scaleBits - UInt32(bitCount)
        let value = (state & mask) >> shift
        advance(start: value << shift, frequency: 1 << shift, scaleBits: scaleBits, mask: mask)
        return value
    }

    /// A well-formed stream ends exactly at its last byte with the encoder's initial state.
    func finish() throws {
        guard !overrun, cursor == end, state == RANS.lowerBound else {
            throw PIXVError.corrupt("entropy stream is desynchronised")
        }
    }
}

/// A probability table normalised so the frequencies sum to exactly `2^scaleBits`.
struct FrequencyTable {
    let scaleBits: Int
    private(set) var frequency: [UInt16]
    private(set) var start: [UInt16]

    var alphabetSize: Int { frequency.count }
    /// True when no symbol was ever observed (the stream it describes is empty).
    var isEmpty: Bool { frequency.allSatisfy { $0 == 0 } }

    /// Builds a table from raw occurrence counts. Every observed symbol keeps a non-zero frequency.
    init(counts: [Int], scaleBits: Int) {
        let target = 1 << scaleBits
        let total = counts.reduce(0, +)
        var scaled = [Int](repeating: 0, count: counts.count)

        if total > 0 {
            let observed = counts.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
            precondition(observed <= target, "alphabet too large for probability resolution")

            var sum = 0
            var largest = 0
            for (symbol, count) in counts.enumerated() where count > 0 {
                let value = max(1, Int((Double(count) * Double(target) / Double(total)).rounded()))
                scaled[symbol] = value
                sum += value
                if count > counts[largest] { largest = symbol }
            }

            if sum < target {
                scaled[largest] += target - sum
            } else if sum > target {
                // Rounding rare symbols up to 1 over-allocated the range; take it back
                // proportionally from the frequent symbols.
                var excess = sum - target
                let order = scaled.indices.filter { scaled[$0] > 1 }.sorted { scaled[$0] > scaled[$1] }
                while excess > 0 {
                    for symbol in order where excess > 0 && scaled[symbol] > 1 {
                        let share = max(1, scaled[symbol] * excess / sum)
                        let taken = min(share, scaled[symbol] - 1, excess)
                        scaled[symbol] -= taken
                        excess -= taken
                    }
                }
            }
        }
        self.init(scaleBits: scaleBits, frequencies: scaled)
    }

    private init(scaleBits: Int, frequencies: [Int]) {
        self.scaleBits = scaleBits
        frequency = frequencies.map { UInt16($0) }
        start = []
        start.reserveCapacity(frequencies.count)
        var running = 0
        for value in frequencies {
            start.append(UInt16(truncatingIfNeeded: running))
            running += value
        }
    }

    @inline(__always)
    func token(_ symbol: Int) -> UInt32 {
        RANS.token(start: UInt32(start[symbol]), frequency: UInt32(frequency[symbol]))
    }

    // MARK: Serialisation

    /// Layout: `varint usedAlphabet`, then one varint frequency per symbol. A zero frequency is
    /// followed by a varint holding the number of *additional* zeros in the run.
    func write(to writer: inout ByteWriter) {
        let used = (frequency.lastIndex { $0 != 0 }).map { $0 + 1 } ?? 0
        writer.varint(used)
        var symbol = 0
        while symbol < used {
            let value = Int(frequency[symbol])
            writer.varint(value)
            if value == 0 {
                var run = 1
                while symbol + run < used, frequency[symbol + run] == 0 { run += 1 }
                writer.varint(run - 1)
                symbol += run
            } else {
                symbol += 1
            }
        }
    }

    init(reading reader: inout ByteReader, scaleBits: Int, alphabetSize: Int) throws {
        let used = try reader.varint()
        guard used <= alphabetSize else { throw PIXVError.corrupt("frequency table exceeds its alphabet") }
        var frequencies = [Int](repeating: 0, count: alphabetSize)
        var sum = 0
        var symbol = 0
        while symbol < used {
            let value = try reader.varint()
            if value == 0 {
                let run = try reader.varint() + 1
                guard symbol + run <= used else { throw PIXVError.corrupt("frequency table zero-run overflows") }
                symbol += run
            } else {
                frequencies[symbol] = value
                sum += value
                guard sum <= 1 << scaleBits else { throw PIXVError.corrupt("frequency table does not normalise") }
                symbol += 1
            }
        }
        guard sum == 0 || sum == 1 << scaleBits else {
            throw PIXVError.corrupt("frequency table does not normalise")
        }
        self.init(scaleBits: scaleBits, frequencies: frequencies)
    }
}

// MARK: - Order-0 streams

/// Decode-side view of a `FrequencyTable`: one lookup from range slot to symbol.
struct SymbolDecodeTable {
    let scaleBits: Int
    let slotToSymbol: [UInt16]
    let frequency: [UInt16]
    let start: [UInt16]

    init(_ table: FrequencyTable) {
        scaleBits = table.scaleBits
        frequency = table.frequency
        start = table.start
        var slots = [UInt16](repeating: 0, count: 1 << table.scaleBits)
        for symbol in 0..<table.alphabetSize {
            let lower = Int(table.start[symbol])
            let count = Int(table.frequency[symbol])
            for slot in lower..<(lower + count) { slots[slot] = UInt16(symbol) }
        }
        slotToSymbol = slots
    }
}

enum SymbolStream {
    /// Entropy-codes `symbols` against a single shared table.
    static func encode(_ symbols: [UInt16], table: FrequencyTable) -> [UInt8] {
        guard !symbols.isEmpty else { return [] }
        var tokens = [UInt32].uninitialized(symbols.count)
        table.start.withUnsafeBufferPointer { start in
            table.frequency.withUnsafeBufferPointer { frequency in
                for index in symbols.indices {
                    let symbol = Int(symbols[index])
                    tokens[index] = RANS.token(start: UInt32(start[symbol]), frequency: UInt32(frequency[symbol]))
                }
            }
        }
        return tokens.withUnsafeBufferPointer { RANS.encode(tokens: $0, scaleBits: table.scaleBits) }
    }

    /// Decodes exactly `count` symbols; throws if the stream does not end cleanly.
    static func decode(_ bytes: UnsafeBufferPointer<UInt8>, count: Int, table: SymbolDecodeTable) throws -> [UInt16] {
        guard count > 0 else {
            guard bytes.isEmpty else { throw PIXVError.corrupt("unexpected data in empty stream") }
            return []
        }
        var decoder = try RansDecoder(bytes)
        var output = [UInt16].uninitialized(count)
        let scale = UInt32(table.scaleBits)
        let mask: UInt32 = (1 << scale) - 1
        table.slotToSymbol.withUnsafeBufferPointer { slots in
            table.frequency.withUnsafeBufferPointer { frequency in
                table.start.withUnsafeBufferPointer { start in
                    output.withUnsafeMutableBufferPointer { out in
                        for index in 0..<count {
                            let symbol = Int(slots[Int(decoder.peek(mask: mask))])
                            out[index] = UInt16(symbol)
                            decoder.advance(start: UInt32(start[symbol]), frequency: UInt32(frequency[symbol]),
                                            scaleBits: scale, mask: mask)
                        }
                    }
                }
            }
        }
        try decoder.finish()
        return output
    }
}

// MARK: - Context-modelled streams

/// A bank of small-alphabet tables selected per symbol by a causal context.
struct ContextTables {
    static let scaleBits = RANS.smallScaleBits

    let contextCount: Int
    let alphabetSize: Int
    private(set) var tables: [FrequencyTable]

    /// `counts[context][symbol]` occurrence counts.
    init(counts: [[Int]], alphabetSize: Int) {
        contextCount = counts.count
        self.alphabetSize = alphabetSize
        tables = counts.map { FrequencyTable(counts: $0, scaleBits: Self.scaleBits) }
    }

    init(reading reader: inout ByteReader, contextCount: Int, alphabetSize: Int) throws {
        self.contextCount = contextCount
        self.alphabetSize = alphabetSize
        tables = []
        tables.reserveCapacity(contextCount)
        for _ in 0..<contextCount {
            tables.append(try FrequencyTable(reading: &reader, scaleBits: Self.scaleBits, alphabetSize: alphabetSize))
        }
    }

    func write(to writer: inout ByteWriter) {
        for table in tables { table.write(to: &writer) }
    }

    @inline(__always)
    func token(context: Int, symbol: Int) -> UInt32 {
        tables[context].token(symbol)
    }

    /// Flattened lookup arrays for the decode loop.
    struct Decoder {
        let alphabetSize: Int
        /// `[context << scaleBits | slot]` → symbol.
        let slotToSymbol: [UInt8]
        /// `[context * alphabetSize + symbol]`.
        let frequency: [UInt16]
        let start: [UInt16]
    }

    func makeDecoder() -> Decoder {
        let slotsPerContext = 1 << Self.scaleBits
        var slots = [UInt8](repeating: 0, count: contextCount * slotsPerContext)
        var frequency = [UInt16](repeating: 0, count: contextCount * alphabetSize)
        var start = [UInt16](repeating: 0, count: contextCount * alphabetSize)
        for (context, table) in tables.enumerated() {
            if table.isEmpty {
                // A context the encoder never visited. Give it a harmless identity entry so a
                // corrupt stream that lands here keeps decoding and fails the final state check.
                frequency[context * alphabetSize] = UInt16(slotsPerContext)
                continue
            }
            for symbol in 0..<alphabetSize {
                let lower = Int(table.start[symbol])
                let count = Int(table.frequency[symbol])
                frequency[context * alphabetSize + symbol] = table.frequency[symbol]
                start[context * alphabetSize + symbol] = table.start[symbol]
                for slot in lower..<(lower + count) {
                    slots[context * slotsPerContext + slot] = UInt8(symbol)
                }
            }
        }
        return Decoder(alphabetSize: alphabetSize, slotToSymbol: slots, frequency: frequency, start: start)
    }
}
