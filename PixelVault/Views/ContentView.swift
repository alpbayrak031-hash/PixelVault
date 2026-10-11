import PixelVaultKit
import SwiftUI
import UniformTypeIdentifiers

/// The window: the conversion list on the left and the focused file on the right. The
/// analysis tools — inspector, pattern dictionary, overlays — stay out of the way until
/// Advanced is switched on.
struct ContentView: View {
    @Environment(VaultModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 0) {
            // The list has nothing to show until a file is added.
            if !model.items.isEmpty {
                SidebarView()
                    .frame(width: 280)
                    .transition(.move(edge: .leading))
                Divider()
            }
            detail
        }
        .animation(.snappy(duration: 0.25), value: model.items.isEmpty)
        .inspector(isPresented: $model.showsAdvanced) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: 330, max: 400)
        }
        .overlay {
            if isDropTargeted { DropHighlight() }
        }
        .navigationTitle(model.documentName.isEmpty ? "PixelVault" : model.documentName)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onDrop(of: [.fileURL, .image, .pixv], isTargeted: $isDropTargeted, perform: handleDrop)
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.image, .pixv, .folder],
                      allowsMultipleSelection: true) { outcome in
            switch outcome {
            case .success(let urls): model.add(urls, focus: true)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: exportBinding, document: model.exportRequest?.document,
                      contentType: model.exportRequest?.contentType ?? .pixv,
                      defaultFilename: model.exportRequest?.filename) { outcome in
            if case .failure(let error) = outcome { model.errorMessage = error.localizedDescription }
            model.exportRequest = nil
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.canvas
                if model.items.isEmpty {
                    WelcomeView()
                } else if let failure = model.focusedFailure {
                    ContentUnavailableView {
                        Label("Can't Open “\(model.documentName)”", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Remove from List") { model.removeFocused() }
                    }
                } else {
                    CompareView()
                }
                if let activity = model.activity {
                    ActivityBadge(text: activity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.showsAdvanced, model.result != nil {
                Divider()
                DictionaryView()
                    .frame(height: 232)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.canvas)
        .animation(.snappy(duration: 0.25), value: model.showsAdvanced)
    }

    private var subtitle: String {
        guard model.hasImage else { return "" }
        let size = model.imagePixelSize
        return "\(Int(size.width)) × \(Int(size.height)) · \(Format.megapixels(Int(size.width * size.height)))"
    }

    private var exportBinding: Binding<Bool> {
        Binding(get: { model.exportRequest != nil }, set: { if !$0 { model.exportRequest = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model

        ToolbarItem(placement: .navigation) {
            Button {
                model.isImporterPresented = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add photos, .pixv files or folders (⌘O)")
        }

        ToolbarItemGroup(placement: .principal) {
            if model.canCompare {
                Picker("Comparison", selection: $model.viewMode) {
                    ForEach(VaultModel.ViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Compare with a draggable split or two synchronised panes")
            }

            if model.showsAdvanced, model.result != nil {
                Picker("Overlay", selection: $model.overlay) {
                    ForEach(model.availableOverlays) { overlay in
                        Text(overlay.title).tag(overlay)
                    }
                }
                .pickerStyle(.segmented)
                .help("Choose what to draw over the compressed image")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let item = model.focusedItem, item.outputURL != nil || item.fileURL != nil {
                Button {
                    model.reveal(item)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help(item.outputURL == nil ? "Show the original in Finder" : "Show the converted file in Finder")
            }

            Menu {
                Button("PixelVault Image (.pixv)…") { model.exportPixelVault() }
                Button("Decoded PNG…") { model.exportPNG() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.result == nil)
            .help("Save a copy somewhere else")

            Toggle(isOn: $model.showsAdvanced) {
                Label("Advanced", systemImage: "slider.horizontal.3")
                    .labelStyle(.titleAndIcon)
            }
            .help("Show or hide the inspector, pattern dictionary and overlays")
        }
    }

    // MARK: Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let model = model
        var accepted = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.add([url]) }
                }
                accepted = true
                continue
            }
            // Images dragged out of other apps arrive as data rather than files.
            for type in [UTType.pixv, .image] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                let name = provider.suggestedName ?? "Dropped Image"
                _ = provider.loadDataRepresentation(for: type) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in model.add(data: data, name: name) }
                }
                accepted = true
                break
            }
        }
        return accepted
    }
}

/// Shown over the canvas while work is in flight.
struct ActivityBadge: View {
    let text: String

    var body: some View {
        CanvasBadge {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text)
            }
        }
    }
}

struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(10)
            .allowsHitTesting(false)
    }
}

/// The empty window: a drop target with the two ways in.
struct WelcomeView: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            PatternMark()
                .frame(width: 92, height: 92)

            VStack(spacing: 8) {
                Text("Drop photos to convert them")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Each photo becomes a small .pixv file, saved right beside the original.\nDrop as many as you like — or whole folders. Drop .pixv files to view them or turn them back into PNGs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            HStack(spacing: 12) {
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("Choose Files…", systemImage: "folder")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button {
                    model.addSample()
                } label: {
                    Label("Try the Sample", systemImage: "sparkles")
                        .padding(.horizontal, 6)
                }
            }
            .controlSize(.large)
        }
        .padding(48)
        .frame(maxWidth: 640)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [8, 7]))
        }
        .padding(40)
    }
}

/// The app's motif: a 4×4 pattern whose brightness traces a diagonal edge.
struct PatternMark: View {
    private static let levels: [[Double]] = [
        [1.00, 0.92, 0.62, 0.26],
        [0.94, 0.74, 0.36, 0.16],
        [0.66, 0.38, 0.18, 0.10],
        [0.30, 0.16, 0.10, 0.07],
    ]

    var body: some View {
        Canvas { context, size in
            let gap = size.width * 0.06
            let tile = (size.width - 3 * gap) / 4
            for row in 0..<4 {
                for column in 0..<4 {
                    let rect = CGRect(x: CGFloat(column) * (tile + gap), y: CGFloat(row) * (tile + gap),
                                      width: tile, height: tile)
                    let mix = Double(row + column) / 6
                    let color = Color(red: 0.56 * (1 - mix) + 0.25 * mix, green: 0.48 * (1 - mix) + 0.84 * mix,
                                      blue: 1.0 * (1 - mix) + 0.88 * mix)
                    context.fill(Path(roundedRect: rect, cornerRadius: tile * 0.24),
                                 with: .color(color.opacity(0.12 + 0.88 * Self.levels[row][column])))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
