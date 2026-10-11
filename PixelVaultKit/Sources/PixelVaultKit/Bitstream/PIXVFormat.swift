import Foundation

/// Errors raised while reading or writing `.pixv` data.
public enum PIXVError: Error, Equatable, Sendable {
    /// The data does not start with the `PIXV` signature.
    case notAPixelVaultFile
    case unsupportedVersion(major: Int, minor: Int)
    /// The data ends before the structure it describes.
    case truncated
    /// The data is structurally invalid; the payload says where.
    case corrupt(String)
    case checksumMismatch
    case invalidDimensions
    case imageDecodingFailed
    case imageEncodingFailed
}

extension PIXVError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAPixelVaultFile:
            "This is not a PixelVault (.pixv) file."
        case .unsupportedVersion(let major, let minor):
            "This file uses PixelVault format \(major).\(minor), which this version cannot read."
        case .truncated:
            "The file is incomplete."
        case .corrupt(let detail):
            "The file is damaged (\(detail))."
        case .checksumMismatch:
            "The file is damaged (checksum mismatch)."
        case .invalidDimensions:
            "The image dimensions are not supported."
        case .imageDecodingFailed:
            "The image could not be read."
        case .imageEncodingFailed:
            "The image could not be written."
        }
    }
}

/// Constants of the `.pixv` container. See `Docs/PIXV-Format.md` for the full specification.
enum PIXVFormat {
    static let magic: [UInt8] = [0x50, 0x49, 0x58, 0x56]  // "PIXV"
    static let versionMajor: UInt8 = 1
    static let versionMinor: UInt8 = 0
    static let headerSize = 24

    /// Patterns are 4×4 blocks.
    static let blockSize = 4
    static let patternLength = 16

    static let maxDimension = 32_768
    static let maxPixelCount = 1 << 27
    static let maxLevels = 6
    static let maxStages = 8
    static let maxPatterns = 4096
    static let maxCodebooks = 16

    /// Quantised gains lie in `±maxGain`, excluding zero.
    static let maxGain = 128
    static let gainAlphabet = 2 * maxGain

    /// Base-layer residual alphabet: 63 literals plus one escape.
    static let baseAlphabet = 64
    static let baseEscape = baseAlphabet - 1
    static let baseEscapeBits = 9
    static let baseContexts = 6

    enum SectionTag {
        static let codebooks: [UInt8] = Array("CBKS".utf8)
        static let plane: [UInt8] = Array("PLNE".utf8)
    }

    enum Flags {
        static let hasAlpha: UInt16 = 1 << 0
    }
}

/// How the pixel data maps to coded planes.
public enum PIXVColorModel: UInt8, Sendable {
    /// A single luma plane.
    case grayscale = 0
    /// BT.601 full-range Y′CbCr with chroma subsampled 2× in both directions.
    case yCbCr420 = 1
}

/// The role of a coded plane.
public enum PIXVPlaneKind: UInt8, Sendable, CaseIterable {
    case luma = 0
    case chromaBlue = 1
    case chromaRed = 2
    case alpha = 3

    public var isChroma: Bool { self == .chromaBlue || self == .chromaRed }

    public var displayName: String {
        switch self {
        case .luma: "Luma"
        case .chromaBlue: "Chroma Cb"
        case .chromaRed: "Chroma Cr"
        case .alpha: "Alpha"
        }
    }
}

/// The fixed 24-byte file header.
struct PIXVHeader: Equatable {
    var flags: UInt16
    var width: Int
    var height: Int
    var colorModel: PIXVColorModel
    /// Number of pattern-coded pyramid levels in the luma plane; 0 stores the plane as its base layer.
    var lumaLevels: Int
    var quality: Int
    var checksum: UInt32
    /// Minor version found in the file; readers accept any minor of a known major.
    var versionMinor = Int(PIXVFormat.versionMinor)

    var hasAlpha: Bool { flags & PIXVFormat.Flags.hasAlpha != 0 }

    func write(to writer: inout ByteWriter) {
        writer.append(PIXVFormat.magic)
        writer.u8(PIXVFormat.versionMajor)
        writer.u8(PIXVFormat.versionMinor)
        writer.u16(flags)
        writer.u32(UInt32(width))
        writer.u32(UInt32(height))
        writer.u8(colorModel.rawValue)
        writer.u8(UInt8(lumaLevels))
        writer.u8(UInt8(PIXVFormat.blockSize.trailingZeroBitCount))
        writer.u8(UInt8(clamping: quality))
        writer.u32(checksum)
    }

    init(flags: UInt16, width: Int, height: Int, colorModel: PIXVColorModel, lumaLevels: Int, quality: Int, checksum: UInt32) {
        self.flags = flags
        self.width = width
        self.height = height
        self.colorModel = colorModel
        self.lumaLevels = lumaLevels
        self.quality = quality
        self.checksum = checksum
    }

    init(reading reader: inout ByteReader) throws {
        guard reader.remaining >= 4 else { throw PIXVError.notAPixelVaultFile }
        for expected in PIXVFormat.magic {
            guard try reader.u8() == expected else { throw PIXVError.notAPixelVaultFile }
        }
        let major = try reader.u8()
        let minor = try reader.u8()
        guard major == PIXVFormat.versionMajor else {
            throw PIXVError.unsupportedVersion(major: Int(major), minor: Int(minor))
        }
        versionMinor = Int(minor)
        flags = try reader.u16()
        width = Int(try reader.u32())
        height = Int(try reader.u32())
        guard let model = PIXVColorModel(rawValue: try reader.u8()) else {
            throw PIXVError.corrupt("unknown colour model")
        }
        colorModel = model
        lumaLevels = Int(try reader.u8())
        let blockShift = try reader.u8()
        quality = Int(try reader.u8())
        checksum = try reader.u32()

        guard width > 0, height > 0,
              width <= PIXVFormat.maxDimension, height <= PIXVFormat.maxDimension,
              width * height <= PIXVFormat.maxPixelCount
        else { throw PIXVError.invalidDimensions }
        guard blockShift == PIXVFormat.blockSize.trailingZeroBitCount else {
            throw PIXVError.corrupt("unsupported block size")
        }
        guard (0...PIXVFormat.maxLevels).contains(lumaLevels) else {
            throw PIXVError.corrupt("unsupported pyramid depth")
        }
    }
}

/// Geometry shared by encoder and decoder: how the image is padded and how deep each pyramid goes.
struct PIXVGeometry: Equatable {
    let width: Int
    let height: Int
    let lumaLevels: Int
    let chromaLevels: Int
    /// Luma plane dimensions after padding to the pyramid's alignment.
    let paddedWidth: Int
    let paddedHeight: Int

    init(width: Int, height: Int, lumaLevels: Int) {
        self.width = width
        self.height = height
        self.lumaLevels = lumaLevels
        // Chroma starts at half resolution, so it needs one level fewer to reach the same base size.
        chromaLevels = max(0, lumaLevels - 1)
        // A plane with n ≥ 1 levels must split into whole 4×4 blocks at its coarsest level,
        // which takes 2^(n+1) samples; chroma additionally needs the luma size to be even.
        let lumaAlignment = lumaLevels >= 1 ? 1 << (lumaLevels + 1) : 1
        let chromaAlignment = chromaLevels >= 1 ? 1 << (chromaLevels + 2) : 2
        let alignment = max(lumaAlignment, chromaAlignment)
        paddedWidth = (width + alignment - 1) / alignment * alignment
        paddedHeight = (height + alignment - 1) / alignment * alignment
    }

    /// Pyramid depth an encoder should pick for an image of this size. Images too small to
    /// fill a dictionary get no pattern levels at all: their base layer *is* the image.
    static func recommendedLevels(width: Int, height: Int) -> Int {
        let shortSide = min(width, height)
        if shortSide >= 192 { return 3 }
        if shortSide >= 64 { return 2 }
        if shortSide >= 24 { return 1 }
        return 0
    }

    func levels(for kind: PIXVPlaneKind) -> Int {
        kind.isChroma ? chromaLevels : lumaLevels
    }

    func planeSize(for kind: PIXVPlaneKind) -> (width: Int, height: Int) {
        kind.isChroma ? (paddedWidth / 2, paddedHeight / 2) : (paddedWidth, paddedHeight)
    }
}
