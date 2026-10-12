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

    /// The files highlighted in the list — what Convert acts on.
    var selection: Set<ConversionItem.ID> = [] {
        didSet { if selection != oldValue { selectionChanged() } }
    }

    /// The selected item shown in the viewer.
    private(set) var focusedID: ConversionItem.ID? {
        didSet { if focusedID != oldValue { focusChanged() } }
    }

    var focusedItem: ConversionItem? {
        items.first { $0.id == focusedID }
    }

    var selectedItems: [ConversionItem] {
        items.filter { selection.contains($0.id) }
    }

    // MARK: The viewer

    private(set) var source: SourceImage?
    private(set) var result: CompressionResult?
    /// A short description of work in progress for the viewer, or `nil` when idle.
    private(set) var activity: String?
    var errorMessage: String?

    // MARK: Controls

    /// The quality Convert uses. The photo in the viewer follows it live, as a preview.
    var quality = Double(PixelVault.defaultQuality) {
        didSet { if Int(quality.rounded()) != Int(oldValue.rounded()) { pump() } }
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

    /// Totals over the photos converted so far.
    var conversionTotals: (count: Int, sourceBytes: Int, outputBytes: Int) {
        let finished = items.filter { $0.kind == .image && $0.phase == .done && $0.outputSize != nil && $0.sourceSize != nil }
        return (finished.count, finished.reduce(0) { $0 + ($1.sourceSize ?? 0) },
                finished.reduce(0) { $0 + ($1.outputSize ?? 0) })
    }

    /// Why the focused item has nothing to show, if it failed to open.
    var focusedFailure: String? {
        guard result == nil, source == nil, case .failed(let message) = focusedItem?.phase else { return nil }
        return message
    }

    // MARK: Adding and removing

    /// Adds files and the contents of folders to the list and selects them, ready to convert.
    func add(_ urls: [URL]) {
        Task {
            let files = await Task.detached(priority: .userInitiated) { Pipeline.convertibleFiles(in: urls) }.value
            guard !files.isEmpty else {
                if !urls.isEmpty { errorMessage = "PixelVault can't read \(urls.count == 1 ? "that file" : "any of those files")." }
                return
            }
            var added: Set<ConversionItem.ID> = []
            for file in files.map(\.standardizedFileURL) {
                if let existing = items.first(where: { $0.fileURL == file }) {
                    added.insert(existing.id)
                } else {
                    let item = ConversionItem(origin: .file(file))
                    items.append(item)
                    added.insert(item.id)
                }
            }
            selection = added
            loadThumbnails()
        }
    }

    /// Adds image data that has no file behind it; it can be viewed and exported, not converted in place.
    func add(data: Data, name: String) {
        let item = ConversionItem(origin: .data(data, name: name))
        items.append(item)
        selection = [item.id]
        loadThumbnails()
    }

    func addSample() {
        if let existing = items.first(where: { if case .sample = $0.origin { true } else { false } }) {
            selection = [existing.id]
        } else {
            let item = ConversionItem(origin: .sample)
            items.append(item)
            selection = [item.id]
        }
    }

    func remove(_ ids: Set<ConversionItem.ID>) {
        guard let firstIndex = items.firstIndex(where: { ids.contains($0.id) }) else { return }
        items.removeAll { ids.contains($0.id) }
        // Keep something on show: the item that slid into the first removed slot.
        if selection.isSubset(of: ids) {
            selection = items.isEmpty ? [] : [items[min(firstIndex, items.count - 1)].id]
        } else {
            selection.subtract(ids)
        }
    }

    func removeSelected() {
        remove(selection)
    }

    func clearList() {
        items.removeAll()
        selection = []
    }

    func reveal(_ item: ConversionItem) {
        if let url = item.outputURL ?? item.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: Converting

    /// True when Convert has something to write for this item: a photo not yet converted at
    /// the current quality, or a `.pixv` not yet written out as PNG.
    func canConvert(_ item: ConversionItem) -> Bool {
        guard item.savesBesideOriginal, !item.isBusy else { return false }
        switch item.kind {
        case .image: return item.outputURL == nil || item.outputQuality != Int(quality.rounded())
        case .pixv: return item.outputURL == nil
        }
    }

    /// The selected files Convert would act on.
    var convertibleSelection: [ConversionItem] {
        selectedItems.filter(canConvert)
    }

    /// Converts every selected file and saves the result beside it: photos become `.pixv`
    /// at the current quality, `.pixv` files become PNG.
    func convertSelected() {
        convert(Set(convertibleSelection.map(\.id)))
    }

    func convert(_ ids: Set<ConversionItem.ID>) {
        let quality = Int(quality.rounded())
        for item in items where ids.contains(item.id) && canConvert(item) {
            item.queuedQuality = quality
            item.phase = .waiting
        }
        pump()
    }

    // MARK: Work scheduling

    private var isBusy = false
    /// Bumped whenever the focus moves, so results for an item no longer on show are not displayed.
    private var focusGeneration = 0
    private var isFocusLoaded = false
    /// A live quality that failed to encode, so it is not retried in a loop.
    private var failedLiveQuality: Int?

    /// Keeps the viewer on a selected item: the one already on show if it is still selected,
    /// otherwise the first selected in list order.
    private func selectionChanged() {
        if let focusedID, selection.contains(focusedID) { return }
        focusedID = items.first { selection.contains($0.id) }?.id
    }

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

    /// Starts the most urgent job, if nothing is running. What the user is looking at comes
    /// first; queued conversions follow in list order.
    private func pump() {
        guard !isBusy else { return }
        let liveQuality = Int(quality.rounded())

        if let item = focusedItem {
            if !isFocusLoaded {
                return startViewing(item, quality: liveQuality)
            }
            if item.kind == .image, let source, let result,
               result.quality != liveQuality, failedLiveQuality != liveQuality {
                return startReencoding(source: source, quality: liveQuality)
            }
        }
        if let item = items.first(where: { $0.phase == .waiting }) {
            return startConverting(item)
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

    // MARK: Jobs

    private func startViewing(_ item: ConversionItem, quality: Int) {
        let generation = focusGeneration
        let origin = item.origin

        run {
            try Pipeline.view(origin, quality: quality)
        } completion: { [self] outcome in
            switch outcome {
            case .success(.image(let source, let compressed)):
                item.formatName = source.formatName
                item.sourceSize = source.fileSize ?? item.sourceSize
                if item.thumbnail == nil { item.thumbnail = Pipeline.thumbnail(of: source.cgImage) }
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
            }
            if generation == focusGeneration {
                isFocusLoaded = true
                activity = nil
            }
        }
    }

    /// Re-encodes the photo already in the viewer — what makes the quality control live.
    private func startReencoding(source: SourceImage, quality: Int) {
        let generation = focusGeneration
        run {
            try Pipeline.compress(source.image, quality: quality)
        } completion: { [self] outcome in
            guard generation == focusGeneration else { return }
            switch outcome {
            case .success(let compressed):
                adopt(compressed)
            case .failure(let error):
                failedLiveQuality = quality
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startConverting(_ item: ConversionItem) {
        guard let url = item.fileURL else {
            item.phase = .idle
            return pump()
        }
        let existing = item.outputURL
        let quality = item.queuedQuality
        item.phase = .working

        switch item.kind {
        case .image:
            run {
                try Pipeline.convert(url, quality: quality, replacing: existing)
            } completion: { outcome in
                switch outcome {
                case .success(let converted):
                    item.formatName = converted.formatName
                    item.sourceSize = converted.sourceSize
                    item.outputURL = converted.saved.url
                    item.outputSize = converted.saved.size
                    item.outputQuality = quality
                    item.phase = .done
                case .failure(let error):
                    item.phase = .failed(error.localizedDescription)
                }
            }
        case .pixv:
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
