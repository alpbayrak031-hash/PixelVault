import Observation
import PixelVaultKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's single source of truth: the open image, its compressed form, and how the
/// user is looking at them. Heavy work is handed to `Pipeline` off the main actor.
@MainActor
@Observable
final class VaultModel {
    enum ViewMode: String, CaseIterable, Identifiable {
        case split, sideBySide

        var id: Self { self }

        var title: String {
            switch self {
            case .split: "Split"
            case .sideBySide: "Side by Side"
            }
        }

        var symbol: String {
            switch self {
            case .split: "rectangle.split.2x1"
            case .sideBySide: "rectangle.on.rectangle"
            }
        }
    }

    enum Overlay: String, CaseIterable, Identifiable {
        case none, blocks, patterns, error

        var id: Self { self }

        var title: String {
            switch self {
            case .none: "Image"
            case .blocks: "Blocks"
            case .patterns: "Patterns"
            case .error: "Error"
            }
        }

        var symbol: String {
            switch self {
            case .none: "photo"
            case .blocks: "square.grid.3x3.square"
            case .patterns: "paintpalette"
            case .error: "waveform.path.ecg"
            }
        }

        var help: String {
            switch self {
            case .none: "Show the compressed image as it decodes"
            case .blocks: "Show how the image is chunked: where 4, 8 and 16 pixel blocks carry patterns"
            case .patterns: "Colour every block by the dictionary pattern it uses"
            case .error: "Show where the compressed image differs from the original"
            }
        }
    }

    /// What lies under the pointer.
    struct Hover: Equatable {
        var x: Int
        var y: Int
    }

    // MARK: Content

    private(set) var source: SourceImage?
    private(set) var result: CompressionResult?
    private(set) var documentName = ""
    /// A short description of work in progress, or `nil` when idle.
    private(set) var activity: String?
    var errorMessage: String?

    // MARK: Controls

    var quality = Double(PixelVault.defaultQuality) {
        didSet { if Int(quality.rounded()) != Int(oldValue.rounded()) { scheduleEncode() } }
    }

    var viewMode = ViewMode.split
    var overlay = Overlay.none { didSet { if overlay != oldValue { refreshOverlay() } } }
    var overlayOpacity = 0.8
    /// Position of the split divider across the canvas, 0…1.
    var splitFraction: CGFloat = 0.5
    var viewport = Viewport()
    var showsInspector = true
    var showsDictionary = true
    var isImporterPresented = false
    var exportRequest: ExportRequest?

    /// The dictionary shown in the pattern browser and used by the Patterns overlay.
    var selectedCodebookID: Int? {
        didSet {
            guard selectedCodebookID != oldValue else { return }
            selectedPattern = nil
            refreshOverlay()
        }
    }

    /// A pattern picked for highlighting, as an index into the selected dictionary.
    var selectedPattern: Int? { didSet { if selectedPattern != oldValue { refreshOverlay() } } }

    var hover: Hover?
    private(set) var overlayLayer: OverlayLayer?

    // MARK: Derived

    var hasImage: Bool { result != nil || source != nil }
    var canCompare: Bool { source != nil && result != nil }

    var selectedCodebook: PIXVAnalysis.Codebook? {
        guard let analysis = result?.analysis else { return nil }
        return selectedCodebookID.flatMap(analysis.codebook(id:)) ?? analysis.codebooks.first
    }

    /// The overlays that make sense for what is open.
    var availableOverlays: [Overlay] {
        Overlay.allCases.filter { $0 != .error || source != nil }
    }

    /// How many times smaller the `.pixv` is than the file the image came from.
    var compressionRatio: Double? {
        guard let result, let size = source?.fileSize, !result.data.isEmpty else { return nil }
        return Double(size) / Double(result.data.count)
    }

    var imagePixelSize: CGSize {
        if let image = result?.image ?? source?.image {
            return CGSize(width: image.width, height: image.height)
        }
        return .zero
    }

    /// The pyramid blocks under the pointer, finest first.
    var hoverProbes: [PIXVVisualizer.BlockProbe] {
        guard let hover, let analysis = result?.analysis else { return [] }
        return PIXVVisualizer.probe(analysis, plane: probePlane, x: hover.x, y: hover.y)
    }

    private var probePlane: PIXVPlaneKind {
        selectedCodebook?.role == .chroma && overlay == .patterns ? .chromaBlue : .luma
    }

    // MARK: Opening

    func open(url: URL) {
        load(describing: "Opening \(url.lastPathComponent)…") { try Pipeline.open(url: url) }
    }

    func open(data: Data, name: String) {
        load(describing: "Opening \(name)…") { try Pipeline.open(data: data, name: name, isFile: false) }
    }

    func openSample() {
        load(describing: "Drawing the sample…") { .image(try SampleImage.make()) }
    }

    /// Bumped whenever the open document changes, so stale background results are dropped.
    private var documentGeneration = 0

    private func load(describing activity: String, _ work: @escaping @Sendable () throws -> Pipeline.Opened) {
        documentGeneration += 1
        let generation = documentGeneration
        self.activity = activity
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            guard generation == documentGeneration else { return }
            switch outcome {
            case .success(.image(let image)):
                source = image
                result = nil
                documentName = image.name
                resetView()
                scheduleEncode()
            case .success(.pixv(let opened, let name)):
                source = nil
                documentName = name
                resetView()
                adopt(opened)
                self.activity = nil
            case .failure(let error):
                self.activity = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func closeDocument() {
        documentGeneration += 1
        source = nil
        result = nil
        documentName = ""
        activity = nil
        resetView()
    }

    private func resetView() {
        hover = nil
        overlayLayer = nil
        selectedPattern = nil
        selectedCodebookID = nil
        viewport.fit()
        if overlay == .error { overlay = .none }
    }

    // MARK: Encoding

    private var isEncoding = false
    private var needsEncode = false

    /// Requests a re-encode at the current quality. Requests made while one is running
    /// collapse into a single follow-up, so dragging the slider never queues stale work.
    private func scheduleEncode() {
        guard source != nil else { return }
        if isEncoding {
            needsEncode = true
        } else {
            encode()
        }
    }

    private func encode() {
        guard let source else { return }
        isEncoding = true
        needsEncode = false
        let generation = documentGeneration
        let quality = Int(quality.rounded())
        if result == nil { activity = "Compressing…" }

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try Pipeline.compress(source.image, quality: quality) }
            }.value
            isEncoding = false
            if generation == documentGeneration {
                switch outcome {
                case .success(let compressed):
                    adopt(compressed)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
                activity = nil
            }
            if needsEncode { encode() }
        }
    }

    private func adopt(_ compressed: CompressionResult) {
        result = compressed
        // Dictionaries are re-learned on every encode, so a pattern index does not carry
        // over; the choice of dictionary does, when it still exists.
        selectedPattern = nil
        let codebooks = compressed.analysis.codebooks
        if !codebooks.contains(where: { $0.id == selectedCodebookID }) {
            selectedCodebookID = codebooks.first?.id
        }
        refreshOverlay()
    }

    // MARK: Overlay

    private var overlayGeneration = 0

    private func refreshOverlay() {
        overlayGeneration += 1
        guard let result, overlay != .none else {
            overlayLayer = nil
            return
        }
        let kind: Pipeline.OverlayKind
        switch overlay {
        case .none:
            return
        case .blocks:
            kind = .blocks
        case .patterns:
            guard let codebook = selectedCodebook else {
                overlayLayer = nil
                return
            }
            kind = .patterns(codebookID: codebook.id, highlight: selectedPattern)
        case .error:
            kind = .error
        }

        let generation = overlayGeneration
        let original = source?.image
        Task {
            let layer = await Task.detached(priority: .userInitiated) {
                Pipeline.overlay(kind, result: result, original: original)
            }.value
            if generation == overlayGeneration { overlayLayer = layer }
        }
    }

    // MARK: Selection

    /// Picks the pattern used by the block under an image point, and shows everywhere else it repeats.
    func selectPattern(atImageX x: Int, y: Int) {
        guard let analysis = result?.analysis else { return }
        let probes = PIXVVisualizer.probe(analysis, plane: probePlane, x: x, y: y)

        // Prefer the finest block that uses the dictionary already on show.
        if let id = selectedCodebook?.id {
            for probe in probes {
                if let layer = probe.layers.first(where: { $0.codebookID == id }) {
                    select(pattern: layer.pattern, in: id)
                    return
                }
            }
        }
        if let layer = probes.lazy.compactMap(\.layers.first).first {
            select(pattern: layer.pattern, in: layer.codebookID)
        } else {
            selectedPattern = nil
        }
    }

    func select(pattern: Int?, in codebookID: Int) {
        if selectedCodebookID != codebookID { selectedCodebookID = codebookID }
        selectedPattern = pattern == selectedPattern ? nil : pattern
        if selectedPattern != nil, overlay != .patterns { overlay = .patterns }
    }

    // MARK: Export

    func exportPixelVault() {
        guard let result else { return }
        exportRequest = ExportRequest(document: ExportDocument(data: result.data), contentType: .pixv,
                                      filename: documentName.isEmpty ? "Image" : documentName)
    }

    /// Exports the decoded pixels — what the `.pixv` actually contains — as a PNG.
    func exportPNG() {
        guard let result else { return }
        let name = (documentName.isEmpty ? "Image" : documentName) + " (from pixv)"
        let image = result.image
        activity = "Preparing PNG…"
        Task {
            let data = await Task.detached(priority: .userInitiated) { try? image.pngData() }.value
            activity = nil
            if let data {
                exportRequest = ExportRequest(document: ExportDocument(data: data), contentType: .png, filename: name)
            } else {
                errorMessage = PIXVError.imageEncodingFailed.localizedDescription
            }
        }
    }
}
