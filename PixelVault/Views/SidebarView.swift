import PixelVaultKit
import SwiftUI

/// The conversion list: every file added this session, with what became of it. The rows
/// selected here are what the Convert button acts on.
struct SidebarView: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            ForEach(model.items) { item in
                ItemRow(item: item)
                    .tag(item.id)
            }
        }
        .contextMenu(forSelectionType: ConversionItem.ID.self) { ids in
            menu(for: ids)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onDeleteCommand { model.removeSelected() }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
        .background(Theme.panel)
    }

    @ViewBuilder
    private func menu(for ids: Set<ConversionItem.ID>) -> some View {
        let targets = model.items.filter { ids.contains($0.id) }
        if !targets.isEmpty {
            Button(targets.count == 1 ? "Convert" : "Convert \(targets.count) Files") { model.convert(ids) }
                .disabled(!targets.contains(where: model.canConvert))
            if targets.count == 1, let item = targets.first {
                Button("Show in Finder") { model.reveal(item) }
                    .disabled(item.outputURL == nil && item.fileURL == nil)
            }
            Divider()
            Button("Remove from List") { model.remove(ids) }
        }
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
        case .idle:
            EmptyView()
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
            } else {
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
        let source = original.isEmpty ? item.formatName : "\(item.formatName) · \(original)"
        switch item.phase {
        case .failed(let message):
            return message
        case .idle:
            return source
        case .waiting:
            return "Waiting…"
        case .working:
            return "Converting to \(item.outputFormatName)…"
        case .done:
            guard let size = item.outputSize else { return source }
            switch item.kind {
            case .image: return "\(original) → \(Format.bytes(size))"
            case .pixv: return "\(original) → PNG \(Format.bytes(size))"
            }
        }
    }

    private var tooltip: String {
        if let output = item.outputURL { return "Saved as \(output.lastPathComponent) beside the original" }
        if !item.savesBesideOriginal { return "No original file to save beside — use Export" }
        return item.fileURL?.path ?? item.name
    }
}

/// The quality Convert uses, and a running total of what it has saved.
struct SidebarFooter: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.items.contains(where: { $0.kind == .image }) {
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
                    .help("Used when photos are converted. Smaller files keep less fine detail.")
                }
            }

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
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

    private var summary: String {
        let totals = model.conversionTotals
        guard totals.count > 0, totals.outputBytes > 0 else {
            return "Select files and press Convert. Each result is saved beside its original."
        }
        return "\(totals.count) \(totals.count == 1 ? "photo" : "photos") converted: "
            + "\(Format.bytes(totals.sourceBytes)) → \(Format.bytes(totals.outputBytes)), "
            + "\(Format.ratio(Double(totals.sourceBytes) / Double(totals.outputBytes))) smaller. Saved beside the originals."
    }
}
