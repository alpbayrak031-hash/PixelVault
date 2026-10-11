import PixelVaultKit
import SwiftUI

/// The conversion list: every file added this session, with what became of it.
struct SidebarView: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.focusedID) {
            ForEach(model.items) { item in
                ItemRow(item: item)
                    .tag(item.id)
                    .contextMenu { menu(for: item) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onDeleteCommand { model.removeFocused() }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
        .background(Theme.panel)
    }

    @ViewBuilder
    private func menu(for item: ConversionItem) -> some View {
        Button("Show in Finder") { model.reveal(item) }
            .disabled(item.outputURL == nil && item.fileURL == nil)
        if item.kind == .pixv, item.fileURL != nil {
            Button(item.outputURL == nil ? "Save as PNG" : "Save as PNG Again") { model.savePNG(item) }
        }
        Divider()
        Button("Remove from List") { model.remove(item) }
    }
}

struct ItemRow: View {
    let item: ConversionItem

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(isFailure ? 2 : 1)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            accessory
        }
        .padding(.vertical, 3)
        .help(tooltip)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.06))
            if let image = item.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.1)) }
    }

    @ViewBuilder
    private var accessory: some View {
        switch item.phase {
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
        case .working:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .done:
            if let ratio = item.ratio {
                Text(Format.ratio(ratio))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.22), in: Capsule())
                    .foregroundStyle(Theme.accent)
            } else if item.kind == .pixv, item.outputURL != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = item.phase { return true }
        return false
    }

    private var detail: String {
        let original = item.sourceSize.map(Format.bytes) ?? ""
        switch item.phase {
        case .failed(let message):
            return message
        case .waiting:
            return item.kind == .pixv ? "Waiting to save PNG…" : "\(item.formatName) · \(original) · waiting"
        case .working:
            return item.kind == .pixv ? "Saving PNG…" : "Converting…"
        case .done:
            switch item.kind {
            case .image:
                guard let size = item.outputSize else { return "\(item.formatName) · \(original)" }
                return original.isEmpty ? ".pixv · \(Format.bytes(size))" : "\(original) → \(Format.bytes(size))"
            case .pixv:
                if let size = item.outputSize { return "\(original) → PNG \(Format.bytes(size))" }
                return ".pixv · \(original)"
            }
        }
    }

    private var tooltip: String {
        if let output = item.outputURL { return "Saved as \(output.lastPathComponent) beside the original" }
        if item.kind == .image, !item.savesBesideOriginal { return "No original file to save beside — use Export" }
        return item.fileURL?.path ?? item.name
    }
}

/// Quality for the whole list, the one-click PNG export, and a running total.
struct SidebarFooter: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        let totals = model.conversionTotals
        let unsaved = model.pixelVaultItemsWithoutPNG

        VStack(alignment: .leading, spacing: 10) {
            if totals.of > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Quality")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Quality", selection: presetBinding) {
                        ForEach(VaultModel.qualityPresets, id: \.quality) { preset in
                            Text(preset.name).tag(Optional(preset.quality))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Applies to every photo in the list. Smaller files keep less fine detail.")
                }
            }

            if !unsaved.isEmpty {
                Button {
                    model.saveAllPNG()
                } label: {
                    Label(unsaved.count == 1 ? "Save as PNG" : "Save \(unsaved.count) as PNG", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .help("Decode the .pixv files in the list and save each PNG beside its .pixv")
            }

            if totals.of > 0 {
                Text(summary(totals))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// The selected preset, or none when the quality sits between presets.
    private var presetBinding: Binding<Int?> {
        Binding {
            let quality = Int(model.quality.rounded())
            return VaultModel.qualityPresets.contains { $0.quality == quality } ? quality : nil
        } set: { preset in
            if let preset { model.quality = Double(preset) }
        }
    }

    private func summary(_ totals: (count: Int, of: Int, failed: Int, sourceBytes: Int, outputBytes: Int)) -> String {
        var progress = totals.count + totals.failed == totals.of
            ? "\(totals.count) \(totals.count == 1 ? "photo" : "photos") converted"
            : "\(totals.count) of \(totals.of - totals.failed) photos converted"
        if totals.failed > 0 { progress += ", \(totals.failed) couldn't be" }
        guard totals.outputBytes > 0, totals.sourceBytes > 0 else { return progress }
        return "\(progress)\n\(Format.bytes(totals.sourceBytes)) → \(Format.bytes(totals.outputBytes)), "
            + "\(Format.ratio(Double(totals.sourceBytes) / Double(totals.outputBytes))) smaller. Saved beside the originals."
    }
}
