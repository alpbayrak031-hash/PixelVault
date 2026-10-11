import PixelVaultKit
import SwiftUI

/// The pattern dictionary: every 4×4 pattern the file stores, most used first.
/// Selecting one lights up each block of the image that uses it.
struct DictionaryView: View {
    @Environment(VaultModel.self) private var model
    @State private var hoveredPattern: Int?

    var body: some View {
        HStack(spacing: 0) {
            if let analysis = model.result?.analysis, let codebook = model.selectedCodebook {
                PatternDetail(codebook: codebook, pattern: hoveredPattern ?? model.selectedPattern,
                              isPreview: hoveredPattern != nil && hoveredPattern != model.selectedPattern)
                    .frame(width: 236)

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    CodebookPicker(codebooks: analysis.codebooks)
                    Divider()
                    PatternGrid(codebook: codebook, selection: model.selectedPattern, hovered: $hoveredPattern) { pattern in
                        model.select(pattern: pattern, in: codebook.id)
                    }
                    // A fresh grid per dictionary resets scroll position and hover state.
                    .id(codebook.id)
                }
            } else {
                ContentUnavailableView("No Pattern Dictionary", systemImage: "square.grid.4x3.fill",
                                       description: Text("This image is small enough to be stored without patterns."))
            }
        }
        .background(Theme.panel)
    }
}

/// Chooses which dictionary to browse: one per stage, for luma and for chroma.
struct CodebookPicker: View {
    @Environment(VaultModel.self) private var model
    let codebooks: [PIXVAnalysis.Codebook]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Pattern Dictionary")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)

                ForEach(codebooks) { codebook in
                    let isSelected = codebook.id == model.selectedCodebook?.id
                    Button {
                        model.selectedCodebookID = codebook.id
                    } label: {
                        HStack(spacing: 5) {
                            Text(codebook.displayName)
                            Text(Format.count(codebook.patternCount))
                                .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                                .monospacedDigit()
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isSelected ? AnyShapeStyle(Theme.accent.opacity(0.9)) : AnyShapeStyle(Theme.card),
                                    in: Capsule())
                        .overlay { Capsule().strokeBorder(isSelected ? .clear : Theme.hairline) }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(codebook.displayName): \(codebook.patternCount) patterns used by \(Format.count(codebook.totalUsage)) blocks")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}

/// All patterns of one dictionary as a single canvas — thousands of tiles stay cheap that way.
struct PatternGrid: View {
    let codebook: PIXVAnalysis.Codebook
    let selection: Int?
    @Binding var hovered: Int?
    let onSelect: (Int) -> Void

    private let tile: CGFloat = 28
    private let gap: CGFloat = 5
    private let inset: CGFloat = 14

    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var visibleRect: CGRect = .zero

    var body: some View {
        GeometryReader { proxy in
            let columns = max(1, Int((proxy.size.width - 2 * inset + gap) / (tile + gap)))
            let rows = (codebook.patternCount + columns - 1) / columns
            let height = CGFloat(rows) * (tile + gap) - gap + 2 * inset

            ScrollView {
                Canvas { context, _ in
                    draw(in: &context, columns: columns)
                }
                .frame(height: max(height, 1))
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hovered = index(at: location, columns: columns)
                    case .ended: hovered = nil
                    }
                }
                .onTapGesture { location in
                    if let index = index(at: location, columns: columns) { onSelect(index) }
                }
                .accessibilityLabel("\(codebook.displayName), \(codebook.patternCount) patterns")
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in visibleRect = rect }
            .onChange(of: selection) { _, selected in
                // A pattern picked in the image may be far down the list; bring it into view.
                guard let selected, selected < codebook.patternCount else { return }
                let top = origin(of: selected, columns: columns).y
                guard top < visibleRect.minY || top + tile > visibleRect.maxY else { return }
                withAnimation(.snappy(duration: 0.3)) {
                    scrollPosition.scrollTo(y: max(0, top - (visibleRect.height - tile) / 2))
                }
            }
        }
    }

    private func origin(of index: Int, columns: Int) -> CGPoint {
        CGPoint(x: inset + CGFloat(index % columns) * (tile + gap), y: inset + CGFloat(index / columns) * (tile + gap))
    }

    private func index(at location: CGPoint, columns: Int) -> Int? {
        let column = Int((location.x - inset) / (tile + gap)), row = Int((location.y - inset) / (tile + gap))
        guard location.x >= inset, location.y >= inset, column < columns else { return nil }
        // Ignore the gutters between tiles.
        let local = CGPoint(x: location.x - inset - CGFloat(column) * (tile + gap),
                            y: location.y - inset - CGFloat(row) * (tile + gap))
        guard local.x <= tile, local.y <= tile else { return nil }
        let index = row * columns + column
        return index < codebook.patternCount ? index : nil
    }

    private func draw(in context: inout GraphicsContext, columns: Int) {
        let cell = tile / 4
        for index in 0..<codebook.patternCount {
            let corner = origin(of: index, columns: columns)
            let rect = CGRect(x: corner.x, y: corner.y, width: tile, height: tile)
            let shape = Path(roundedRect: rect, cornerRadius: 5)

            var tileContext = context
            tileContext.clip(to: shape)
            let values = PIXVVisualizer.tile(codebook, pattern: index)
            for position in 0..<16 {
                // Overlap cells by a hair so no seams show between them.
                let cellRect = CGRect(x: corner.x + CGFloat(position % 4) * cell, y: corner.y + CGFloat(position / 4) * cell,
                                      width: cell + 0.5, height: cell + 0.5)
                tileContext.fill(Path(cellRect), with: .color(PatternPalette.color(values[position], role: codebook.role)))
            }

            if index == selection {
                context.stroke(Path(roundedRect: rect.insetBy(dx: -2.5, dy: -2.5), cornerRadius: 7),
                               with: .color(Color(red: 1, green: 0.84, blue: 0.04)), lineWidth: 2.5)
            } else if index == hovered {
                context.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 6),
                               with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            } else {
                context.stroke(shape, with: .color(.white.opacity(0.08)), lineWidth: 1)
            }
        }
    }
}

/// Maps a pattern sample (0…1, 0.5 = no change) to a display colour.
enum PatternPalette {
    static func color(_ value: Double, role: PIXVCodebookRole) -> Color {
        switch role {
        case .luma:
            // Patterns add or subtract brightness, so plain greys read truest.
            return Color(white: 0.06 + 0.88 * value)
        case .chroma:
            // Chroma patterns shift colour: cool below neutral, warm above.
            let offset = (value - 0.5) * 2
            return offset >= 0
                ? Color(red: 0.32 + 0.66 * offset, green: 0.32 + 0.20 * offset, blue: 0.34 - 0.10 * offset)
                : Color(red: 0.32 + 0.22 * offset, green: 0.32 - 0.36 * offset, blue: 0.34 - 0.58 * offset)
        }
    }
}

/// A close-up of one pattern and how much of the image it explains.
struct PatternDetail: View {
    let codebook: PIXVAnalysis.Codebook
    let pattern: Int?
    let isPreview: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pattern, pattern < codebook.patternCount {
                HStack(alignment: .top, spacing: 12) {
                    LargeTile(codebook: codebook, pattern: pattern)
                        .frame(width: 88, height: 88)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pattern \(pattern + 1)")
                            .font(.headline)
                        Text("of \(Format.count(codebook.patternCount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(Format.count(codebook.usage[pattern]))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.brand)
                        Text("blocks · \(share(of: pattern))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 88)
                }

                UsageCurve(usage: codebook.usage, marked: pattern)
                    .frame(height: 34)

                Text(isPreview ? "Click to highlight its blocks in the image."
                    : "Highlighted in yellow wherever the image uses it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Image(systemName: "square.grid.4x3.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.brand)
                Text(codebook.displayName)
                    .font(.headline)
                Text("\(Format.count(codebook.patternCount)) patterns rebuild \(Format.count(codebook.totalUsage)) blocks. Each block stores only a pattern number and a strength.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                UsageCurve(usage: codebook.usage, marked: nil)
                    .frame(height: 34)
                Text("Hover a tile to inspect it; click to find it in the image.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func share(of pattern: Int) -> String {
        let total = codebook.totalUsage
        guard total > 0 else { return "0%" }
        return String(format: "%.2f%%", 100 * Double(codebook.usage[pattern]) / Double(total))
    }
}

struct LargeTile: View {
    let codebook: PIXVAnalysis.Codebook
    let pattern: Int

    var body: some View {
        Canvas { context, size in
            let values = PIXVVisualizer.tile(codebook, pattern: pattern)
            let cell = size.width / 4
            for position in 0..<16 {
                let rect = CGRect(x: CGFloat(position % 4) * cell, y: CGFloat(position / 4) * cell, width: cell, height: cell)
                context.fill(Path(rect.insetBy(dx: 0.75, dy: 0.75)),
                             with: .color(PatternPalette.color(values[position], role: codebook.role)))
            }
        }
        .background(.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline) }
        .accessibilityLabel("Pattern \(pattern + 1) enlarged")
    }
}

/// How unevenly the dictionary is used: uses per pattern, most popular on the left.
struct UsageCurve: View {
    let usage: [Int]
    let marked: Int?

    var body: some View {
        Canvas { context, size in
            guard let peak = usage.first, peak > 0, usage.count > 1 else { return }
            // Log scale: popularity spans orders of magnitude.
            let top = log(Double(peak) + 1)
            func point(_ index: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(index) / CGFloat(usage.count - 1),
                        y: size.height * (1 - CGFloat(log(Double(usage[index]) + 1) / top) * 0.92))
            }

            var curve = Path()
            let step = max(1, usage.count / Int(max(size.width, 1)))
            curve.move(to: point(0))
            for index in stride(from: step, to: usage.count, by: step) { curve.addLine(to: point(index)) }
            curve.addLine(to: point(usage.count - 1))

            var area = curve
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(curve, with: .color(Theme.accent), lineWidth: 1.2)

            if let marked, marked < usage.count {
                let position = point(marked)
                context.stroke(Path { $0.move(to: CGPoint(x: position.x, y: 0)); $0.addLine(to: CGPoint(x: position.x, y: size.height)) },
                               with: .color(.white.opacity(0.35)), lineWidth: 1)
                context.fill(Path(ellipseIn: CGRect(x: position.x - 3, y: position.y - 3, width: 6, height: 6)),
                             with: .color(Color(red: 1, green: 0.84, blue: 0.04)))
            }
        }
        .help("Uses per pattern, most used first (logarithmic)")
        .accessibilityLabel("Usage of each pattern, most used first")
    }
}
