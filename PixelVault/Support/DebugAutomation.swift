#if DEBUG
import AppKit
import SwiftUI

/// Scripted UI driving for debug builds, used to capture the window in known states.
///
/// Set `PIXELVAULT_AUTOMATION` to a `;`-separated script, for example
/// `add=/path/Folder;wait;select=all;convert;wait;snap=done;quit`. Screenshot requests are
/// exchanged through `PixelVaultAutomation/` in the temporary directory.
@MainActor
enum DebugAutomation {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PixelVaultAutomation", isDirectory: true)
    }

    static func start(model: VaultModel) {
        guard let script = ProcessInfo.processInfo.environment["PIXELVAULT_AUTOMATION"] else { return }
        Task { await run(script, model: model) }
    }

    private static func run(_ script: String, model: VaultModel) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .milliseconds(600))

        for command in script.split(separator: ";") {
            let parts = command.split(separator: "=", maxSplits: 1).map(String.init)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.count > 1 ? parts[1] : ""
            let numbers = value.split(separator: ",").compactMap { Double($0) }

            switch name {
            case "add":
                // Comma-separated paths; relative ones are looked up in the automation directory.
                let urls = value.split(separator: ",").map { path -> URL in
                    path.hasPrefix("/") ? URL(fileURLWithPath: String(path)) : directory.appendingPathComponent(String(path))
                }
                model.add(urls)
            case "sample":
                model.addSample()
            case "select":
                // `all`, or comma-separated row numbers.
                if value == "all" {
                    model.selection = Set(model.items.map(\.id))
                } else {
                    model.selection = Set(numbers.map(Int.init).filter(model.items.indices.contains).map { model.items[$0].id })
                }
            case "convert":
                model.convertSelected()
            case "advanced":
                model.showsAdvanced = value != "0"
            case "wait":
                // Until the viewer has its file and the whole list has been processed.
                for _ in 0..<1200 {
                    try? await Task.sleep(for: .milliseconds(50))
                    let listSettled = !model.items.contains(where: \.isBusy)
                    if model.activity == nil, listSettled, !model.items.isEmpty { break }
                }
                try? await Task.sleep(for: .milliseconds(700))
            case "sleep":
                try? await Task.sleep(for: .milliseconds(Int((numbers.first ?? 0.5) * 1000)))
            case "size":
                if numbers.count == 2 { window?.setContentSize(NSSize(width: numbers[0], height: numbers[1])) }
            case "overlay":
                if let overlay = VaultModel.Overlay(rawValue: value) { model.overlay = overlay }
            case "mode":
                if let mode = VaultModel.ViewMode(rawValue: value) { model.viewMode = mode }
            case "quality":
                if let quality = numbers.first { model.quality = quality }
            case "split":
                if let fraction = numbers.first { model.splitFraction = fraction }
            case "zoom":
                // Relative to the fitted scale.
                model.viewport.fit()
                if let factor = numbers.first { model.viewport.setScale(model.viewport.fitScale * factor) }
            case "center":
                if numbers.count == 2 {
                    let size = model.imagePixelSize
                    model.viewport.center(on: CGPoint(x: size.width * numbers[0], y: size.height * numbers[1]))
                }
            case "hover":
                if numbers.count == 2 {
                    let size = model.imagePixelSize
                    model.hover = .init(x: Int(size.width * numbers[0]), y: Int(size.height * numbers[1]))
                }
            case "click":
                if numbers.count == 2 {
                    let size = model.imagePixelSize
                    model.selectPattern(atImageX: Int(size.width * numbers[0]), y: Int(size.height * numbers[1]))
                }
            case "codebook":
                if let id = numbers.first { model.selectedCodebookID = Int(id) }
            case "pattern":
                if let pattern = numbers.first, let codebook = model.selectedCodebook {
                    model.select(pattern: Int(pattern), in: codebook.id)
                }
            case "snap":
                try? await Task.sleep(for: .milliseconds(700))
                await requestScreenshot(named: value)
            case "quit":
                NSApp.terminate(nil)
            default:
                print("PixelVault automation: unknown command \(name)")
            }
        }
    }

    private static var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
    }

    /// Asks whoever is driving the app to photograph the window: drops `<name>.request`
    /// and waits for `<name>.done`. (The system compositor draws toolbar glass and the
    /// inspector, which an in-process render cannot reproduce.)
    private static func requestScreenshot(named name: String) async {
        let request = directory.appendingPathComponent("\(name).request")
        let done = directory.appendingPathComponent("\(name).done")
        try? FileManager.default.removeItem(at: done)
        FileManager.default.createFile(atPath: request.path, contents: nil)
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(100))
            if FileManager.default.fileExists(atPath: done.path) { break }
        }
        try? FileManager.default.removeItem(at: request)
        try? FileManager.default.removeItem(at: done)
    }
}
#endif
