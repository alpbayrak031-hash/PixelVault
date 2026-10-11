import AppKit
import Observation
import PixelVaultKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's single source of truth: the list of files being converted, the one on show in
/// the viewer, and how the user is looking at it. Heavy work is handed to `Pipeline` off the
/// main actor, one job at a time — each job already uses every core.
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
    }

    /// What lies under the pointer.
    struct Hover: Equatable {
        var x: Int
        var y: Int
    }

    static let qualityPresets: [(name: String, quality: Int)] = [("Compact", 30), ("Balanced", 60), ("Detailed", 85)]

    // MARK: The list

    private(set) var items: [ConversionItem] = []

    /// The item shown in the viewer.
    var focusedID: ConversionItem.ID? {
        didSet { if focusedID != oldValue { focusChanged() } }
    }

    var focusedItem: ConversionItem? {
        items.first { $0.id == focusedID }
    }

    // MARK: The viewer

    private(set) var source: SourceImage?
    private(set) var result: CompressionResult?
    /// A short description of work in progress for the viewer, or `nil` when idle.
    private(set) var activity: String?
    var errorMessage: String?

    // MARK: Controls

    /// Applies to every photo in the list. The focused photo follows it live; the rest are
    /// re-converted once it stops changing.
    var quality = Double(PixelVault.defaultQuality) {
        didSet { if Int(quality.rounded()) != Int(oldValue.rounded()) { qualityChanged() } }
    }

    var viewMode = ViewMode.split
    var overlay = Overlay.none { didSet { if overlay != oldValue { refreshOverlay() } } }
    var overlayOpacity = 0.8
    /// Position of the split divider across the canvas, 0…1.
    var splitFraction: CGFloat = 0.5
    var viewport = Viewport()

    /// Shows the analysis tools: inspector, pattern dictionary and overlays. Off until asked for.
    var showsAdvanced = false {
        didSet { if !showsAdvanced, overlay != .none { overlay = .none } }
    }

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
    var documentName: String { focusedItem?.name ?? "" }

    var selectedCodebook: PIXVAnalysis.Codebook? {
        guard let analysis = result?.analysis else { return nil }
        return selectedCodebookID.flatMap(analysis.codebook(id:)) ?? analysis.codebooks.first
    }

    /// The overlays that make sense for what is open.
    var availableOverlays: [Overlay] {
        Overlay.allCases.filter { $0 != .error || source != nil }
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

    /// `.pixv` files in the list that have not been written out as PNG.
    var pixelVaultItemsWithoutPNG: [ConversionItem] {
        items.filter { $0.kind == .pixv && $0.fileURL != nil && $0.outputURL == nil && !$0.wantsPNG && $0.phase == .done }
    }

    /// Totals over the photos converted so far.
    var conversionTotals: (count: Int, of: Int, failed: Int, sourceBytes: Int, outputBytes: Int) {
        let photos = items.filter { $0.kind == .image }
        let finished = photos.filter { $0.outputSize != nil && $0.sourceSize != nil && $0.phase == .done }
        let failed = photos.filter { if case .failed = $0.phase { true } else { false } }
        return (finished.count, photos.count, failed.count, finished.reduce(0) { $0 + ($1.sourceSize ?? 0) },
                finished.reduce(0) { $0 + ($1.outputSize ?? 0) })
    }

    /// Why the focused item has nothing to show, if it failed to open.
    var focusedFailure: String? {
        guard result == nil, source == nil, case .failed(let message) = focusedItem?.phase else { return nil }
        return message
    }

    // MARK: Adding and removing

    /// Adds files and the contents of folders to the list. Photos start converting at once.
    func add(_ urls: [URL], focus: Bool = false) {
        Task {
            let files = await Task.detached(priority: .userInitiated) { Pipeline.convertibleFiles(in: urls) }.value
            guard !files.isEmpty else {
                if !urls.isEmpty { errorMessage = "PixelVault can't read \(urls.count == 1 ? "that file" : "any of those files")." }
                return
            }
            var target: ConversionItem?
            for file in files.map(\.standardizedFileURL) {
                if let existing = items.first(where: { $0.fileURL == file }) {
                    target = target ?? existing
                } else {
                    let item = ConversionItem(origin: .file(file))
                    items.append(item)
                    target = target ?? item
                }
            }
            if focus || focusedID == nil, let target { focusedID = target.id }
            loadThumbnails()
            pump()
        }
    }

    /// Adds image data that has no file behind it; it can be viewed and exported, not saved in place.
    func add(data: Data, name: String) {
        let item = ConversionItem(origin: .data(data, name: name))
        items.append(item)
        focusedID = item.id
        loadThumbnails()
    }

    func addSample() {
        if let existing = items.first(where: { if case .sample = $0.origin { true } else { false } }) {
            focusedID = existing.id
        } else {
            let item = ConversionItem(origin: .sample)
            items.append(item)
            focusedID = item.id
        }
    }

    func remove(_ item: ConversionItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        if focusedID == item.id {
            focusedID = items.isEmpty ? nil : items[min(index, items.count - 1)].id
        }
    }

    func removeFocused() {
        if let item = focusedItem { remove(item) }
    }

    func clearList() {
        items.removeAll()
        focusedID = nil
    }

    func reveal(_ item: ConversionItem) {
        if let url = item.outputURL ?? item.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Asks for a `.pixv` in the list to be written back out as a PNG beside it.
    func savePNG(_ item: ConversionItem) {
        guard item.kind == .pixv, item.fileURL != nil else { return }
        item.wantsPNG = true
        item.phase = .waiting
        pump()
    }

    func saveAllPNG() {
        pixelVaultItemsWithoutPNG.forEach(savePNG)
    }

    // MARK: Work scheduling

    private var isBusy = false
    /// Bumped whenever the focus moves, so results for an item no longer on show are not displayed.
    private var focusGeneration = 0
    private var isFocusLoaded = false
    /// The quality the list is being converted at; trails `quality` while the slider moves.
    private var committedQuality = PixelVault.defaultQuality
    private var settleTask: Task<Void, Never>?
    /// A live quality that failed to encode, so it is not retried in a loop.
    private var failedLiveQuality: Int?

    private func focusChanged() {
        focusGeneration += 1
        source = nil
        result = nil
        isFocusLoaded = false
        failedLiveQuality = nil
        hover = nil
        overlayLayer = nil
        selectedPattern = nil
        selectedCodebookID = nil
        viewport.fit()
        if overlay == .error { overlay = .none }
        activity = focusedItem == nil ? nil : "Opening…"
        pump()
    }

    private func qualityChanged() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.committedQuality = Int(self.quality.rounded())
            for item in self.items where self.needsConversion(item) && item.phase != .working {
                item.phase = .waiting
            }
            self.pump()
        }
        pump()
    }

    /// True for a photo in the list whose file on disk is not at the committed quality.
    private func needsConversion(_ item: ConversionItem) -> Bool {
        item.kind == .image && item.savesBesideOriginal && item.attemptedQuality != committedQuality
    }

    /// Starts the most urgent job, if nothing is running. What the user is looking at comes
    /// first; the rest of the list follows in order.
    private func pump() {
        guard !isBusy else { return }
        let liveQuality = Int(quality.rounded())

        if let item = focusedItem {
            if !isFocusLoaded {
                return startViewing(item, quality: liveQuality)
            }
            if item.kind == .image, let source, let result {
                if result.quality != liveQuality, failedLiveQuality != liveQuality {
                    return startReencoding(item, source: source, quality: liveQuality)
                }
                if result.quality == committedQuality, needsConversion(item) {
                    return startSaving(item, data: result.data, quality: committedQuality)
                }
            }
        }
        if let item = items.first(where: \.wantsPNG) {
            return startPNGExport(item)
        }
        if let item = items.first(where: { $0.id != focusedID && needsConversion($0) }) {
            return startConverting(item, quality: committedQuality)
        }
    }

    /// Runs `work` off the main actor, then `completion` back on it, then looks for more to do.
    private func run<Output: Sendable>(_ work: @escaping @Sendable () throws -> Output,
                                       completion: @escaping @MainActor (Result<Output, Error>) -> Void) {
        isBusy = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            isBusy = false
            completion(outcome)
            pump()
        }
    }

    private func record(_ saved: Result<SavedFile, Pipeline.SaveError>?, for item: ConversionItem, quality: Int) {
        guard let saved else { return }
        item.attemptedQuality = quality
        switch saved {
        case .success(let file):
            item.outputURL = file.url
            item.outputSize = file.size
            item.outputQuality = quality
            item.phase = .done
        case .failure(let error):
            item.phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Jobs

    private func startViewing(_ item: ConversionItem, quality: Int) {
        let generation = focusGeneration
        let origin = item.origin
        let save = needsConversion(item) && quality == committedQuality
        let existing = item.outputURL
        if item.kind == .image, item.outputURL == nil { item.phase = .working }

        run {
            try Pipeline.view(origin, quality: quality, save: save, replacing: existing)
        } completion: { [self] outcome in
            switch outcome {
            case .success(.image(let source, let compressed, let saved)):
                item.formatName = source.formatName
                item.sourceSize = source.fileSize ?? item.sourceSize
                if item.thumbnail == nil { item.thumbnail = Pipeline.thumbnail(of: source.cgImage) }
                record(saved, for: item, quality: quality)
                if !item.savesBesideOriginal {
                    item.outputSize = compressed.data.count
                    item.phase = .done
                }
                if generation == focusGeneration {
                    self.source = source
                    adopt(compressed)
                }
            case .success(.pixv(let opened)):
                item.sourceSize = opened.data.count
                if generation == focusGeneration {
                    source = nil
                    adopt(opened)
                }
            case .failure(let error):
                item.phase = .failed(error.localizedDescription)
                item.attemptedQuality = quality
            }
            if generation == focusGeneration {
                isFocusLoaded = true
                activity = nil
            }
        }
    }

    /// Re-encodes the photo already in the viewer — what makes the quality slider live.
    private func startReencoding(_ item: ConversionItem, source: SourceImage, quality: Int) {
        let generation = focusGeneration
        let save = needsConversion(item) && quality == committedQuality
        let url = item.fileURL
        let existing = item.outputURL

        run {
            let compressed = try Pipeline.compress(source.image, quality: quality)
            let saved = save ? url.map {
                Pipeline.write(compressed.data, beside: $0, pathExtension: PixelVault.fileExtension, replacing: existing)
            } : nil
            return (compressed, saved)
        } completion: { [self] outcome in
            switch outcome {
            case .success(let (compressed, saved)):
                record(saved, for: item, quality: quality)
                if !item.savesBesideOriginal { item.outputSize = compressed.data.count }
                if generation == focusGeneration { adopt(compressed) }
            case .failure(let error):
                if generation == focusGeneration {
                    failedLiveQuality = quality
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Writes the encode already on show, once the quality has settled on it.
    private func startSaving(_ item: ConversionItem, data: Data, quality: Int) {
        guard let url = item.fileURL else { return }
        let existing = item.outputURL
        run {
            Pipeline.write(data, beside: url, pathExtension: PixelVault.fileExtension, replacing: existing)
        } completion: { [self] outcome in
            if case .success(let saved) = outcome { record(saved, for: item, quality: quality) }
        }
    }

    private func startConverting(_ item: ConversionItem, quality: Int) {
        guard let url = item.fileURL else { return }
        let existing = item.outputURL
        item.phase = .working
        run {
            try Pipeline.convert(url, quality: quality, replacing: existing)
        } completion: { [self] outcome in
            switch outcome {
            case .success(let converted):
                item.formatName = converted.formatName
                item.sourceSize = converted.sourceSize
                record(.success(converted.saved), for: item, quality: quality)
            case .failure(let error):
                item.attemptedQuality = quality
                item.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func startPNGExport(_ item: ConversionItem) {
        guard let url = item.fileURL else {
            item.wantsPNG = false
            return
        }
        item.wantsPNG = false
        item.phase = .working
        let existing = item.outputURL
        run {
            try Pipeline.exportPNG(fromPixelVaultAt: url, replacing: existing)
        } completion: { outcome in
            switch outcome {
            case .success(let file):
                item.outputURL = file.url
                item.outputSize = file.size
                item.phase = .done
            case .failure(let error):
                item.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Thumbnails

    private var isLoadingThumbnails = false

    /// Fills in list thumbnails one at a time, alongside the conversion work.
    private func loadThumbnails() {
        guard !isLoadingThumbnails,
              let item = items.first(where: { $0.thumbnail == nil && !$0.hasTriedThumbnail })
        else { return }
        isLoadingThumbnails = true
        item.hasTriedThumbnail = true
        let origin = item.origin
        Task {
            let image = await Task.detached(priority: .utility) { Pipeline.thumbnail(for: origin) }.value
            if item.thumbnail == nil { item.thumbnail = image }
            isLoadingThumbnails = false
            loadThumbnails()
        }
    }

    // MARK: Viewer state

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

    // MARK: Pattern selection

    /// Picks the pattern used by the block under an image point, and shows everywhere else it repeats.
    func selectPattern(atImageX x: Int, y: Int) {
        guard showsAdvanced, let analysis = result?.analysis else { return }
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

    // MARK: Export through a save panel

    /// For when the file should go somewhere other than beside its original.
    func exportPixelVault() {
        guard let result else { return }
        exportRequest = ExportRequest(document: ExportDocument(data: result.data), contentType: .pixv,
                                      filename: documentName.isEmpty ? "Image" : documentName)
    }

    /// Exports the decoded pixels — what the `.pixv` actually contains — as a PNG.
    func exportPNG() {
        guard let result else { return }
        let name = documentName.isEmpty ? "Image" : documentName
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
