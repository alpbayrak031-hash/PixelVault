import PixelVaultKit
import SwiftUI

/// Colours and shared styling for the app's dark, photo-first look.
enum Theme {
    static let canvas = Color(red: 0.047, green: 0.050, blue: 0.062)
    static let panel = Color(red: 0.082, green: 0.086, blue: 0.104)
    static let card = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.09)

    static let accent = Color(red: 0.56, green: 0.48, blue: 1.0)
    static let accentCool = Color(red: 0.25, green: 0.84, blue: 0.88)
    static let brand = LinearGradient(colors: [accent, accentCool], startPoint: .leading, endPoint: .trailing)

    /// Colour identifying a pyramid level, shared by the block overlay and its legends.
    static func level(_ level: Int) -> Color {
        let color = PIXVVisualizer.levelColor(level)
        return Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
    }

    static func category(_ category: PIXVSizeCategory) -> Color {
        switch category {
        case .patternIndices: accent
        case .gains: Color(red: 0.78, green: 0.52, blue: 1.0)
        case .baseLayer: accentCool
        case .blockModes: Color(red: 0.36, green: 0.80, blue: 0.56)
        case .dictionary: Color(red: 1.0, green: 0.76, blue: 0.30)
        case .container: Color.white.opacity(0.35)
        }
    }
}

/// A rounded panel that groups related readouts.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title)
                } icon: {
                    if let symbol { Image(systemName: symbol) }
                }
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline)
        }
    }
}

/// A floating label drawn over the image canvas.
struct CanvasBadge<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.12)) }
    }
}

enum Format {
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func milliseconds(_ value: Double) -> String {
        value < 100 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    static func ratio(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f×", value) : String(format: "%.1f×", value)
    }

    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        return value > 0 && value < 1 ? "<1%" : String(format: "%.0f%%", value)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func megapixels(_ pixels: Int) -> String {
        String(format: "%.1f MP", Double(pixels) / 1_000_000)
    }
}
