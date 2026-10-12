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

    var quality: Int { analysis.quality }
}

/// An image drawn over the compressed view. `cellSize` image pixels map to one overlay pixel.
struct OverlayLayer: Sendable {
    let image: CGImage
    let cellSize: Int
}

/// A file the app wrote beside an original.
struct SavedFile: Sendable {
    let url: URL
    let size: Int
}

/// The app's background work. Everything here is synchronous and runs off the main actor.
enum Pipeline {
    /// An item opened for the viewer.
    enum Viewed: Sendable {
        case image(SourceImage, CompressionResult)
        case pixv(CompressionResult)
    }

    /// The outcome of converting a file without keeping its pixels.
    struct Converted: Sendable {
        let saved: SavedFile
        let sourceSize: Int
        let formatName: String
    }

    /// Conversion worked but the result could not be written beside the original.
    struct SaveError: Error, LocalizedError, Sendable {
        let folder: String
        let reason: String

        var errorDescription: String? {
            "Couldn't save in “\(folder)”: \(reason)"
        }
    }

    enum OverlayKind: Sendable {
        case blocks
        case patterns(codebookID: Int, highlight: Int?)
        case error
    }

    // MARK: Viewing

    /// Loads an item for the viewer. Photos are compressed at `quality` in memory, as a
    /// preview of what Convert would write; nothing touches the disk.
    static func view(_ origin: ConversionItem.Origin, quality: Int) throws -> Viewed {
        let source: SourceImage
        switch origin {
        case .sample:
            source = try SampleImage.make()
        case .data(let data, let name):
            source = try sourceImage(from: data, name: name, fileSize: nil)
        case .file(let url):
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if PixelVault.isPixelVaultData(data) {
                return .pixv(try result(decoding: data, original: nil, encodeTimings: nil))
            }
            source = try sourceImage(from: data, name: url.deletingPathExtension().lastPathComponent, fileSize: data.count)
        }
        return .image(source, try compress(source.image, quality: quality))
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

    private static func sourceImage(from data: Data, name: String, fileSize: Int?) throws -> SourceImage {
        let image = try RGBAImage(imageData: data)
        return SourceImage(name: name, formatName: formatName(of: data), fileSize: fileSize, image: image,
                           cgImage: try image.makeCGImage())
    }

    // MARK: Converting files

    /// Photo → `.pixv`, written beside the original. Keeps nothing in memory afterwards,
    /// so a long list costs no more than one image at a time.
    static func convert(_ url: URL, quality: Int, replacing existing: URL?) throws -> Converted {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !PixelVault.isPixelVaultData(data) else { throw PIXVError.imageDecodingFailed }
        let image = try RGBAImage(imageData: data)
        let encoded = try PixelVault.encode(image, quality: quality)
        let saved = try write(encoded.data, beside: url, pathExtension: PixelVault.fileExtension, replacing: existing).get()
        return Converted(saved: saved, sourceSize: data.count, formatName: formatName(of: data))
    }

    /// `.pixv` → PNG, written beside the `.pixv`.
    static func exportPNG(fromPixelVaultAt url: URL, replacing existing: URL?) throws -> SavedFile {
        let decoded = try PixelVault.decode(try Data(contentsOf: url, options: .mappedIfSafe))
        return try write(try decoded.image.pngData(), beside: url, pathExtension: "png", replacing: existing).get()
    }

    /// Writes `data` next to `original` with a new extension. Files the app did not create
    /// are never overwritten: if the natural name is taken, a number is appended, Finder style.
    static func write(_ data: Data, beside original: URL, pathExtension: String,
                      replacing existing: URL?) -> Result<SavedFile, SaveError> {
        let destination = existing ?? freeURL(beside: original, pathExtension: pathExtension)
        do {
            try data.write(to: destination, options: .atomic)
            return .success(SavedFile(url: destination, size: data.count))
        } catch {
            return .failure(SaveError(folder: original.deletingLastPathComponent().lastPathComponent,
                                      reason: error.localizedDescription))
        }
    }

    private static func freeURL(beside original: URL, pathExtension: String) -> URL {
        let folder = original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(pathExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension(pathExtension)
            number += 1
        }
        return candidate
    }

    // MARK: Adding files

    /// Expands folders into the convertible files inside them and drops everything else.
    static func convertibleFiles(in urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let entry = contents?.nextObject() as? URL, files.count < 5000 {
                    if isConvertible(entry) { files.append(entry) }
                }
            } else if isConvertible(url) {
                files.append(url)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func isConvertible(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == PixelVault.fileExtension { return true }
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        else { return false }
        return type.conforms(to: .image)
    }

    // MARK: Thumbnails

    /// A small picture for the list. Cheap for both kinds: ImageIO subsamples while
    /// decoding, and a `.pixv` only needs the top of its pyramid.
    static func thumbnail(for origin: ConversionItem.Origin, side: Int = 112) -> CGImage? {
        switch origin {
        case .sample:
            return nil
        case .data(let data, _):
            return CGImageSourceCreateWithData(data as CFData, nil).flatMap { thumbnail(from: $0, side: side) }
        case .file(let url):
            if url.pathExtension.lowercased() == PixelVault.fileExtension {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return try? PixelVault.decodePreview(data, minimumLongSide: side).makeCGImage()
            }
            return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { thumbnail(from: $0, side: side) }
        }
    }

    private static func thumbnail(from source: CGImageSource, side: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Shrinks an image already in memory to list size.
    static func thumbnail(of image: CGImage, side: Int = 112) -> CGImage? {
        let scale = min(1, CGFloat(side) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: Overlays

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
