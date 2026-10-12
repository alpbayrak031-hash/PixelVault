import CoreGraphics
import Foundation
import Observation

/// One entry in the conversion list: a photo to turn into `.pixv`, or a `.pixv` to view and
/// optionally turn back into a PNG.
@MainActor
@Observable
final class ConversionItem: Identifiable {
    /// Where the item's bytes come from.
    enum Origin: Sendable {
        case file(URL)
        /// Image data dragged in from another app, with no file behind it.
        case data(Data, name: String)
        case sample
    }

    enum Kind: Sendable {
        case image, pixv
    }

    enum Phase: Equatable {
        /// In the list, nothing written yet (or nothing asked for since the last result).
        case idle
        /// Queued by Convert.
        case waiting
        case working
        /// The converted file has been written beside the original.
        case done
        case failed(String)
    }

    nonisolated let id = UUID()
    let origin: Origin
    let kind: Kind
    let name: String

    var phase: Phase
    var thumbnail: CGImage?
    var hasTriedThumbnail = false

    /// Short format label of the original, such as "JPEG".
    var formatName: String
    /// Size of the original file, once known.
    var sourceSize: Int?

    /// The converted file written beside the original.
    var outputURL: URL?
    var outputSize: Int?
    /// Quality the file at `outputURL` was encoded with (photos only).
    var outputQuality: Int?
    /// Quality to convert at, set when Convert queues the item.
    var queuedQuality = 0

    init(origin: Origin) {
        self.origin = origin
        switch origin {
        case .file(let url):
            name = url.deletingPathExtension().lastPathComponent
            let fileExtension = url.pathExtension.lowercased()
            kind = fileExtension == "pixv" ? .pixv : .image
            formatName = kind == .pixv ? ".pixv" : (fileExtension == "jpg" ? "JPEG" : fileExtension.uppercased())
            sourceSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        case .data(let data, let dataName):
            name = dataName
            kind = .image
            formatName = "Image"
            sourceSize = data.count
        case .sample:
            name = SampleImage.name
            kind = .image
            formatName = "PNG"
            sourceSize = nil
        }
        phase = .idle
    }

    var fileURL: URL? {
        if case .file(let url) = origin { return url }
        return nil
    }

    /// Converted files are written beside the original, so only items that came from a file
    /// can be converted in place.
    var savesBesideOriginal: Bool { fileURL != nil }

    var isBusy: Bool { phase == .waiting || phase == .working }

    /// What Convert produces for this item.
    var outputFormatName: String { kind == .pixv ? "PNG" : ".pixv" }

    /// How many times smaller the converted file is than the original.
    var ratio: Double? {
        guard kind == .image, let sourceSize, let outputSize, outputSize > 0 else { return nil }
        return Double(sourceSize) / Double(outputSize)
    }
}
