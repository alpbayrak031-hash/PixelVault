import Foundation
import Testing
@testable import PixelVaultKit

@Suite("Entropy coding")
struct EntropyCodingTests {
    private func roundTrip(_ symbols: [UInt16], alphabetSize: Int, scaleBits: Int) throws -> (decoded: [UInt16], bytes: Int) {
        var counts = [Int](repeating: 0, count: alphabetSize)
        for symbol in symbols { counts[Int(symbol)] += 1 }
        let table = FrequencyTable(counts: counts, scaleBits: scaleBits)
        let encoded = SymbolStream.encode(symbols, table: table)
        let decoded = try encoded.withUnsafeBufferPointer {
            try SymbolStream.decode($0, count: symbols.count, table: SymbolDecodeTable(table))
        }
        return (decoded, encoded.count)
    }

    @Test("rANS round-trips skewed symbol streams", arguments: [12, 15])
    func skewedRoundTrip(scaleBits: Int) throws {
        var generator = SplitMix64(seed: 99)
        // Geometric-ish distribution over 200 symbols.
        let symbols = (0..<50_000).map { _ -> UInt16 in
            UInt16(min(199, (generator.next() % 64).trailingZeroBitCount * 20 + Int(generator.next() % 20)))
        }
        let result = try roundTrip(symbols, alphabetSize: 200, scaleBits: scaleBits)
        #expect(result.decoded == symbols)
        // A skewed source must compress well below one byte per symbol.
        #expect(result.bytes < symbols.count)
    }

    @Test("rANS handles a full 4096-symbol alphabet")
    func largeAlphabet() throws {
        var generator = SplitMix64(seed: 3)
        let symbols = (0..<100_000).map { _ in UInt16(generator.next() % 4096) }
        #expect(try roundTrip(symbols, alphabetSize: 4096, scaleBits: RANS.largeScaleBits).decoded == symbols)
    }

    @Test("A single repeated symbol costs almost nothing")
    func degenerateDistribution() throws {
        let symbols = [UInt16](repeating: 5, count: 100_000)
        let result = try roundTrip(symbols, alphabetSize: 16, scaleBits: 12)
        #expect(result.decoded == symbols)
        #expect(result.bytes <= 8)
    }

    @Test("An empty stream encodes to nothing")
    func emptyStream() throws {
        let table = FrequencyTable(counts: [0, 0, 0], scaleBits: 12)
        #expect(SymbolStream.encode([], table: table).isEmpty)
        #expect(table.isEmpty)
    }

    @Test("Frequency tables always normalise and survive serialisation")
    func tableNormalisation() throws {
        var generator = SplitMix64(seed: 1234)
        for trial in 0..<200 {
            let alphabetSize = 1 + Int(generator.next() % 300)
            let scaleBits = alphabetSize <= 256 && trial % 2 == 0 ? 12 : 15
            // Wildly uneven counts with many zeros, the hard case for normalisation.
            let counts = (0..<alphabetSize).map { _ -> Int in
                switch generator.next() % 4 {
                case 0: 0
                case 1: 1
                case 2: Int(generator.next() % 50)
                default: Int(generator.next() % 1_000_000)
                }
            }
            let table = FrequencyTable(counts: counts, scaleBits: scaleBits)
            let sum = table.frequency.reduce(0) { $0 + Int($1) }
            #expect(sum == (counts.contains { $0 > 0 } ? 1 << scaleBits : 0))
            for symbol in 0..<alphabetSize {
                #expect((counts[symbol] > 0) == (table.frequency[symbol] > 0), "observed symbols keep a slot")
            }

            var writer = ByteWriter()
            table.write(to: &writer)
            var reader = ByteReader(writer.bytes)
            let restored = try FrequencyTable(reading: &reader, scaleBits: scaleBits, alphabetSize: alphabetSize)
            #expect(restored.frequency == table.frequency)
            #expect(restored.start == table.start)
            #expect(reader.isAtEnd)
        }
    }

    @Test("A truncated entropy stream is reported, not trusted")
    func truncatedStream() throws {
        var generator = SplitMix64(seed: 5)
        let symbols = (0..<10_000).map { _ in UInt16(generator.next() % 64) }
        var counts = [Int](repeating: 0, count: 64)
        for symbol in symbols { counts[Int(symbol)] += 1 }
        let table = FrequencyTable(counts: counts, scaleBits: 12)
        let encoded = SymbolStream.encode(symbols, table: table)
        for length in [0, 3, 4, encoded.count / 2, encoded.count - 1] {
            #expect(throws: PIXVError.self) {
                try encoded.prefix(length).withUnsafeBufferPointer {
                    try SymbolStream.decode($0, count: symbols.count, table: SymbolDecodeTable(table))
                }
            }
        }
    }

    @Test("Varints round-trip across their range")
    func varints() throws {
        let values = [0, 1, 127, 128, 255, 16_383, 16_384, 1 << 20, Int(Int32.max)]
        var writer = ByteWriter()
        for value in values { writer.varint(value) }
        var reader = ByteReader(writer.bytes)
        for value in values { #expect(try reader.varint() == value) }
        #expect(reader.isAtEnd)
    }

    @Test("CRC-32 matches the standard check value")
    func crc() {
        let bytes = Array("123456789".utf8)
        #expect(bytes.withUnsafeBufferPointer { CRC32.checksum($0) } == 0xCBF4_3926)
    }
}
