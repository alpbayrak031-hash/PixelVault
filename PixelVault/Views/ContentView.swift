import PixelVaultKit
import SwiftUI
import UniformTypeIdentifiers

/// The window: image canvas, pattern dictionary beneath it, inspector alongside.
struct ContentView: View {
    @Environment(VaultModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ZStack {
                Theme.canvas
                if model.hasImage {
                    CompareView()
                } else {
                    WelcomeView()
                }
                if let activity = model.activity {
                    ActivityBadge(text: activity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.showsDictionary, model.result != nil {
                Divider()
                DictionaryView()
                    .frame(height: 232)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.canvas)
        .overlay {
            if isDropTargeted { DropHighlight() }
        }
        .inspector(isPresented: $model.showsInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: 330, max: 400)
        }
        .animation(.snappy(duration: 0.25), value: model.showsDictionary)
        .navigationTitle(model.documentName.isEmpty ? "PixelVault" : model.documentName)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onDrop(of: [.fileURL, .image, .pixv], isTargeted: $isDropTargeted, perform: handleDrop)
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.image, .pixv]) { outcome in
            switch outcome {
            case .success(let url): model.open(url: url)
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
                Label("Open", systemImage: "photo.badge.plus")
            }
            .help("Open an image or a .pixv file (⌘O)")
        }

        ToolbarItemGroup(placement: .principal) {
            Picker("Comparison", selection: $model.viewMode) {
                ForEach(VaultModel.ViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.canCompare)
            .help("Compare with a draggable split or two synchronised panes")

            Picker("Overlay", selection: $model.overlay) {
                ForEach(model.availableOverlays) { overlay in
                    Text(overlay.title).tag(overlay)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.result == nil)
            .help("Choose what to draw over the compressed image")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("PixelVault Image (.pixv)…") { model.exportPixelVault() }
                Button("Decoded PNG…") { model.exportPNG() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.result == nil)
            .help("Export the compressed file, or its decoded pixels")

            Button {
                model.showsDictionary.toggle()
            } label: {
                Label("Dictionary", systemImage: "square.grid.4x3.fill")
            }
            .help("Show or hide the pattern dictionary")

            Button {
                model.showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
        }
    }

    // MARK: Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let model = model

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.open(url: url) }
            }
            return true
        }
        // Images dragged out of other apps arrive as data rather than files.
        for type in [UTType.pixv, .image] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let name = provider.suggestedName ?? "Dropped Image"
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                guard let data else { return }
                Task { @MainActor in model.open(data: data, name: name) }
            }
            return true
        }
        return false
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
                Text("Drop a photo to compress it")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("PixelVault rebuilds your image from a small dictionary of 4×4 patterns.\nOpen a JPEG, PNG or HEIC to convert it — or a .pixv file to look inside.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            HStack(spacing: 12) {
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("Open Image…", systemImage: "folder")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button {
                    model.openSample()
                } label: {
                    Label("Try the Sample", systemImage: "sparkles")
                        .padding(.horizontal, 6)
                }
            }
            .controlSize(.large)
        }
        .padding(48)
        .frame(maxWidth: 620)
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
