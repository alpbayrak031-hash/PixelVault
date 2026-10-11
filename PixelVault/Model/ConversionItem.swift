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
        /// Queued for conversion.
        case waiting
        case working
        /// Converted, or — for a `.pixv` that is only being viewed — nothing to do.
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
    /// Quality the file at `outputURL` was encoded with.
    var outputQuality: Int?
    /// Quality of the most recent conversion attempt, successful or not.
    var attemptedQuality: Int?
    /// Set when the user asks for a `.pixv` to be written back out as a PNG.
    var wantsPNG = false

    init(origin: Origin) {
        self.origin = origin
        switch origin {
        case .file(let url):
            name = url.deletingPathExtension().lastPathComponent
            kind = url.pathExtension.lowercased() == "pixv" ? .pixv : .image
            formatName = kind == .pixv ? ".pixv" : url.pathExtension.uppercased()
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
        phase = kind == .pixv ? .done : .waiting
    }

    var fileURL: URL? {
        if case .file(let url) = origin { return url }
        return nil
    }

    /// Converted files are only written for items that came from a file: "beside the
    /// original" needs an original.
    var savesBesideOriginal: Bool { fileURL != nil }

    /// How many times smaller the converted file is than the original.
    var ratio: Double? {
        guard kind == .image, let sourceSize, let outputSize, outputSize > 0 else { return nil }
        return Double(sourceSize) / Double(outputSize)
    }
}
