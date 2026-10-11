import Foundation

/// The result of compressing an image.
public struct PIXVEncodeResult: Sendable {
    /// The complete `.pixv` file.
    public let data: Data
    public let timings: PIXVEncodeTimings
}

/// Stage timings of one decode, in milliseconds.
public struct PIXVDecodeTimings: Sendable {
    /// Parsing the container and entropy-decoding every stream.
    public var entropyDecoding: Double = 0
    /// Rebuilding the planes from patterns and converting back to RGB.
    public var reconstruction: Double = 0
    public var total: Double = 0
}

/// The result of opening a `.pixv` file.
public struct PIXVDecodeResult: Sendable {
    public let image: RGBAImage
    /// The file's internal structure, for inspection and visualisation.
    public let analysis: PIXVAnalysis
    public let timings: PIXVDecodeTimings
}

/// What a `.pixv` header says about its image.
public struct PIXVFileInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let colorModel: PIXVColorModel
    public let hasAlpha: Bool
    /// The quality setting (1–100) the file was written with.
    public let quality: Int
    public let versionMajor: Int
    public let versionMinor: Int
}

/// PixelVault's `.pixv` image codec.
///
/// `.pixv` stores an image as a small dictionary of 4×4 patterns plus, for each block, the
/// pattern to use and how strongly to apply it. The image is coded as a resolution pyramid,
/// so smooth regions are carried by a handful of coarse blocks and only detailed regions
/// spend bits on fine ones.
///
/// All entry points are synchronous, thread-safe and internally parallel; call them off the
/// main thread.
public enum PixelVault {
    public static let fileExtension = "pixv"
    /// Uniform Type Identifier the app exports for `.pixv` files.
    public static let typeIdentifier = "com.pixelvault.pixv"
    public static let qualityRange = 1...100
    public static let defaultQuality = 60

    /// Compresses `image`. `quality` runs from 1 (smallest) to 100 (most faithful).
    public static func encode(_ image: RGBAImage, quality: Int = defaultQuality) throws -> PIXVEncodeResult {
        let clock = Stopwatch()
        var (coded, timings) = try Encoder.encode(image, quality: quality)
        var entropyClock = Stopwatch()
        let bytes = Container.write(coded).bytes
        timings.entropyCoding = entropyClock.lap()
        timings.total = clock.milliseconds
        return PIXVEncodeResult(data: Data(bytes), timings: timings)
    }

    /// Decompresses a `.pixv` file and reports its structure.
    public static func decode(_ data: Data) throws -> PIXVDecodeResult {
        let clock = Stopwatch()
        var stage = Stopwatch()
        var timings = PIXVDecodeTimings()

        let bytes = [UInt8](data)
        let (coded, sizes) = try Container.read(bytes)
        timings.entropyDecoding = stage.lap()

        let image = try Reconstructor.render(coded)
        timings.reconstruction = stage.lap()
        timings.total = clock.milliseconds

        let analysis = PIXVAnalysis(coded, sizes: sizes, fileSize: bytes.count)
        return PIXVDecodeResult(image: image, analysis: analysis, timings: timings)
    }

    /// Decodes a smaller rendition of a `.pixv` file for thumbnails and previews.
    ///
    /// The format is a resolution pyramid, so stopping early yields the image at 1/2, 1/4 or
    /// 1/8 size while skipping most of the decoding work and memory. The result is the
    /// smallest of those whose longer side is still at least `minimumLongSide` pixels, or the
    /// full image when none is.
    public static func decodePreview(_ data: Data, minimumLongSide: Int) throws -> RGBAImage {
        let bytes = [UInt8](data)
        let header = try Container.readHeader(bytes)
        let longSide = max(header.width, header.height)
        var reduction = 0
        while reduction < header.lumaLevels, longSide >> (reduction + 1) >= minimumLongSide {
            reduction += 1
        }
        return try Reconstructor.render(try Container.read(bytes, reduction: reduction).image)
    }

    /// True when `data` starts with the `.pixv` signature.
    public static func isPixelVaultData(_ data: Data) -> Bool {
        data.count >= PIXVFormat.magic.count && data.prefix(PIXVFormat.magic.count).elementsEqual(PIXVFormat.magic)
    }

    /// Reads the header only — cheap enough to call for previews and validation.
    public static func readInfo(_ data: Data) throws -> PIXVFileInfo {
        let header = try Container.readHeader([UInt8](data.prefix(PIXVFormat.headerSize)))
        return PIXVFileInfo(width: header.width, height: header.height, colorModel: header.colorModel,
                            hasAlpha: header.hasAlpha, quality: header.quality,
                            versionMajor: Int(PIXVFormat.versionMajor), versionMinor: header.versionMinor)
    }
}
