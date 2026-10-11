import SwiftUI

@main
struct PixelVaultApp: App {
    @State private var model = VaultModel()

    var body: some Scene {
        Window("PixelVault", id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1040, minHeight: 660)
                .onOpenURL { model.open(url: $0) }
                #if DEBUG
                .task { DebugAutomation.start(model: model) }
                #endif
        }
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(model: model) }
    }
}

/// Menu-bar commands. Everything here is also reachable from the toolbar.
struct AppCommands: Commands {
    @Bindable var model: VaultModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.isImporterPresented = true }
                .keyboardShortcut("o")
            Button("Open Sample Image") { model.openSample() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Close Image") { model.closeDocument() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!model.hasImage)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Export as PixelVault Image…") { model.exportPixelVault() }
                .keyboardShortcut("s")
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
            Picker("Overlay", selection: $model.overlay) {
                ForEach(Array(model.availableOverlays.enumerated()), id: \.element) { index, overlay in
                    Text(overlay.title).tag(overlay)
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .disabled(model.result == nil)
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
            Toggle("Pattern Dictionary", isOn: $model.showsDictionary)
                .keyboardShortcut("d", modifiers: [.command, .option])
            Toggle("Inspector", isOn: $model.showsInspector)
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
    }
}
