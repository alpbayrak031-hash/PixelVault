import Foundation

/// Append-only little-endian byte sink.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(reservingCapacity capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    var count: Int { bytes.count }

    mutating func u8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    /// Unsigned LEB128.
    mutating func varint(_ value: Int) {
        precondition(value >= 0, "varint is unsigned")
        var remaining = UInt64(value)
        while remaining >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }

    mutating func append(_ other: [UInt8]) {
        bytes.append(contentsOf: other)
    }

    mutating func append(_ other: ArraySlice<UInt8>) {
        bytes.append(contentsOf: other)
    }
}

/// Bounds-checked little-endian reader over a byte range. Every read throws
/// `PIXVError.truncated` rather than running past the end.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int
    let end: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
        self.end = bytes.count
    }

    init(_ bytes: [UInt8], range: Range<Int>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= bytes.count)
        self.bytes = bytes
        self.offset = range.lowerBound
        self.end = range.upperBound
    }

    var remaining: Int { end - offset }
    var isAtEnd: Bool { offset >= end }

    mutating func u8() throws -> UInt8 {
        guard offset < end else { throw PIXVError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw PIXVError.truncated }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw PIXVError.truncated }
        defer { offset += 4 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    /// Unsigned LEB128, capped at 2^31 so a hostile file cannot request absurd sizes.
    mutating func varint() throws -> Int {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift <= 28 else { throw PIXVError.corrupt("varint too long") }
        }
        guard result <= UInt64(Int32.max) else { throw PIXVError.corrupt("varint out of range") }
        return Int(result)
    }

    /// Consumes `count` bytes and returns their range in `bytes`.
    mutating func take(_ count: Int) throws -> Range<Int> {
        guard count >= 0, count <= remaining else { throw PIXVError.truncated }
        defer { offset += count }
        return offset..<(offset + count)
    }
}

/// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320) — the same checksum PNG and zip use.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        table.withUnsafeBufferPointer { lookup in
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc = lookup[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            return crc ^ 0xFFFF_FFFF
        }
    }

    static func checksum(_ bytes: [UInt8], range: Range<Int>) -> UInt32 {
        bytes.withUnsafeBufferPointer { checksum(UnsafeBufferPointer(rebasing: $0[range])) }
    }
}
