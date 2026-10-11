import SwiftUI

@main
struct PixelVaultApp: App {
    @State private var model = VaultModel()

    var body: some Scene {
        Window("PixelVault", id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 600)
                // Files opened from Finder — double-clicked .pixv files included — land here.
                .onOpenURL { model.add([$0], focus: true) }
                #if DEBUG
                .task { DebugAutomation.start(model: model) }
                #endif
        }
        .defaultSize(width: 1400, height: 860)
        .commands { AppCommands(model: model) }
    }
}

/// Menu-bar commands. Everything here is also reachable from the window.
struct AppCommands: Commands {
    @Bindable var model: VaultModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { model.isImporterPresented = true }
                .keyboardShortcut("o")
            Button("Add Sample Image") { model.addSample() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Show in Finder") {
                if let item = model.focusedItem { model.reveal(item) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.focusedItem?.fileURL == nil)
            Button("Remove from List") { model.removeFocused() }
                .keyboardShortcut(.delete)
                .disabled(model.focusedItem == nil)
            Button("Clear List") { model.clearList() }
                .disabled(model.items.isEmpty)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save All .pixv Files as PNG") { model.saveAllPNG() }
                .disabled(model.pixelVaultItemsWithoutPNG.isEmpty)
            Divider()
            Button("Export as PixelVault Image…") { model.exportPixelVault() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.result == nil)
            Button("Export Decoded PNG…") { model.exportPNG() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.result == nil)
        }
        CommandGroup(after: .toolbar) {
            Picker("Comparison", selection: $model.viewMode) {
                ForEach(VaultModel.ViewMode.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!model.canCompare)
            Divider()
            Button("Zoom In") { model.viewport.zoom(by: 1.5) }
                .keyboardShortcut("+")
                .disabled(!model.hasImage)
            Button("Zoom Out") { model.viewport.zoom(by: 1 / 1.5) }
                .keyboardShortcut("-")
                .disabled(!model.hasImage)
            Button("Zoom to Fit") { model.viewport.fit() }
                .keyboardShortcut("0")
                .disabled(!model.hasImage)
            Divider()
            Toggle("Advanced Tools", isOn: $model.showsAdvanced)
                .keyboardShortcut("a", modifiers: [.command, .option])
            Picker("Overlay", selection: $model.overlay) {
                ForEach(Array(model.availableOverlays.enumerated()), id: \.element) { index, overlay in
                    Text(overlay.title).tag(overlay)
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .disabled(!model.showsAdvanced || model.result == nil)
            Divider()
        }
    }
}
