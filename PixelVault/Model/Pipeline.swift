import CoreGraphics
import Foundation
import ImageIO
import PixelVaultKit
import UniformTypeIdentifiers

/// An image the user brought in, before compression.
struct SourceImage: Sendable {
    let name: String
    /// Short format label such as "JPEG" or "HEIC".
    let formatName: String
    /// Size of the file it came from, when it came from one.
    let fileSize: Int?
    let image: RGBAImage
    let cgImage: CGImage

    /// Bytes the pixels take uncompressed.
    var rawSize: Int { image.pixelCount * (image.hasAlpha ? 4 : 3) }
}

/// A `.pixv` file together with everything the UI shows about it.
struct CompressionResult: Sendable {
    let data: Data
    let image: RGBAImage
    let cgImage: CGImage
    let analysis: PIXVAnalysis
    /// Absent when the file was opened rather than produced in this session.
    let encodeTimings: PIXVEncodeTimings?
    let decodeTimings: PIXVDecodeTimings
    /// Fidelity against the original, when the original is known.
    let psnr: Double?
}

/// An image drawn over the compressed view. `cellSize` image pixels map to one overlay pixel.
struct OverlayLayer: Sendable {
    let image: CGImage
    let cellSize: Int
}

/// The app's background work. Everything here is synchronous and runs off the main actor.
enum Pipeline {
    enum Opened: Sendable {
        case image(SourceImage)
        case pixv(CompressionResult, name: String)
    }

    enum OverlayKind: Sendable {
        case blocks
        case patterns(codebookID: Int, highlight: Int?)
        case error
    }

    static func open(url: URL) throws -> Opened {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try open(data: data, name: url.deletingPathExtension().lastPathComponent, isFile: true)
    }

    static func open(data: Data, name: String, isFile: Bool) throws -> Opened {
        if PixelVault.isPixelVaultData(data) {
            return .pixv(try result(decoding: data, original: nil, encodeTimings: nil), name: name)
        }
        let image = try RGBAImage(imageData: data)
        return .image(SourceImage(name: name, formatName: formatName(of: data), fileSize: isFile ? data.count : nil,
                                  image: image, cgImage: try image.makeCGImage()))
    }

    /// Encodes, then decodes the bytes just produced. Decoding the real file — rather than
    /// reusing the encoder's state — is what makes the timings and the preview honest.
    static func compress(_ source: RGBAImage, quality: Int) throws -> CompressionResult {
        let encoded = try PixelVault.encode(source, quality: quality)
        return try result(decoding: encoded.data, original: source, encodeTimings: encoded.timings)
    }

    private static func result(decoding data: Data, original: RGBAImage?,
                               encodeTimings: PIXVEncodeTimings?) throws -> CompressionResult {
        let decoded = try PixelVault.decode(data)
        return CompressionResult(data: data, image: decoded.image, cgImage: try decoded.image.makeCGImage(),
                                 analysis: decoded.analysis, encodeTimings: encodeTimings,
                                 decodeTimings: decoded.timings,
                                 psnr: original.map { ImageMetrics.psnr($0, decoded.image) })
    }

    static func overlay(_ kind: OverlayKind, result: CompressionResult, original: RGBAImage?) -> OverlayLayer? {
        switch kind {
        case .blocks:
            return PIXVVisualizer.structureMap(result.analysis).flatMap(layer)
        case .patterns(let codebookID, let highlight):
            return PIXVVisualizer.patternMap(result.analysis, codebookID: codebookID, highlight: highlight).flatMap(layer)
        case .error:
            guard let original, original.width == result.image.width, original.height == result.image.height,
                  let image = try? PIXVVisualizer.errorMap(original: original, decoded: result.image).makeCGImage()
            else { return nil }
            return OverlayLayer(image: image, cellSize: 1)
        }
    }

    private static func layer(_ map: PIXVVisualizer.Map) -> OverlayLayer? {
        (try? map.image.makeCGImage()).map { OverlayLayer(image: $0, cellSize: map.cellSize) }
    }

    private static func formatName(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier)
        else { return "Image" }
        if type.conforms(to: .jpeg) { return "JPEG" }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "HEIC" }
        return type.preferredFilenameExtension?.uppercased() ?? "Image"
    }
}
