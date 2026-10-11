import PixelVaultKit
import SwiftUI

/// The image canvas: original against compressed, as a draggable split or two locked panes.
struct CompareView: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        ZStack {
            if let result = model.result {
                if let source = model.source {
                    switch model.viewMode {
                    case .split:
                        SplitComparison(source: source, result: result)
                    case .sideBySide:
                        // The 1-point gap lets a hairline show through as the pane separator.
                        HStack(spacing: 1) {
                            ViewportPane { frame, _ in
                                ImageLayer(image: source.cgImage, frame: frame)
                                PaneLabel(title: "Original", detail: originalDetail(source), alignment: .topLeading)
                            }
                            .background(Theme.canvas)
                            ViewportPane { frame, size in
                                CompressedLayers(result: result, frame: frame, paneSize: size)
                                PaneLabel(title: ".pixv", detail: Format.bytes(result.data.count), alignment: .topLeading,
                                          tint: Theme.accent)
                            }
                            .background(Theme.canvas)
                        }
                        .background(Color.white.opacity(0.18))
                    }
                } else {
                    // A .pixv opened directly: there is no original to compare against.
                    ViewportPane { frame, size in
                        CompressedLayers(result: result, frame: frame, paneSize: size)
                        PaneLabel(title: ".pixv", detail: Format.bytes(result.data.count), alignment: .topLeading,
                                  tint: Theme.accent)
                    }
                }
            } else if let source = model.source {
                // First encode still running: show the original meanwhile.
                ViewportPane { frame, _ in
                    ImageLayer(image: source.cgImage, frame: frame)
                }
            }

            CanvasChrome()
        }
    }
}

func originalDetail(_ source: SourceImage) -> String {
    if let size = source.fileSize {
        return "\(source.formatName) · \(Format.bytes(size))"
    }
    return source.formatName
}

// MARK: - Layers

/// One image drawn at `frame`. Past 150 % it switches to nearest-neighbour sampling, so
/// individual pixels — and compression artefacts — are shown as they are.
struct ImageLayer: View {
    @Environment(\.displayScale) private var displayScale
    let image: CGImage
    let frame: CGRect

    var body: some View {
        let magnification = frame.width / CGFloat(image.width) * displayScale
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(magnification > 1.5 ? .none : .high)
            .frame(width: max(frame.width, 1), height: max(frame.height, 1))
            .offset(x: frame.minX, y: frame.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The compressed image with whichever overlay is active, plus block outlines when zoomed in.
struct CompressedLayers: View {
    @Environment(VaultModel.self) private var model
    let result: CompressionResult
    let frame: CGRect
    let paneSize: CGSize

    var body: some View {
        ImageLayer(image: result.cgImage, frame: frame)

        if let layer = model.overlayLayer {
            // Structure maps cover the codec's padded area; clip them back to the image.
            let scale = frame.width / CGFloat(result.image.width) * CGFloat(layer.cellSize)
            let overlayFrame = CGRect(x: frame.minX, y: frame.minY, width: CGFloat(layer.image.width) * scale,
                                      height: CGFloat(layer.image.height) * scale)
            Image(decorative: layer.image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: max(overlayFrame.width, 1), height: max(overlayFrame.height, 1))
                .offset(x: overlayFrame.minX, y: overlayFrame.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: max(frame.width, 0), height: max(frame.height, 0))
                        .offset(x: frame.minX, y: frame.minY)
                }
                .opacity(model.overlay == .error ? 1 : model.overlayOpacity)
                .allowsHitTesting(false)
        }

        BlockOutlines(analysis: result.analysis, frame: frame, paneSize: paneSize)
            .allowsHitTesting(false)
    }
}

/// Outlines pattern-carrying blocks once they are large enough on screen to read, and
/// marks the block under the pointer.
struct BlockOutlines: View {
    @Environment(VaultModel.self) private var model
    let analysis: PIXVAnalysis
    let frame: CGRect
    let paneSize: CGSize

    var body: some View {
        let showsGrid = model.overlay == .blocks || model.overlay == .patterns
        let probes = model.showsAdvanced ? model.hoverProbes : []
        let scale = frame.width / CGFloat(max(analysis.width, 1))

        Canvas { context, size in
            let visible = CGRect(origin: .zero, size: size).intersection(frame)
            guard !visible.isEmpty else { return }

            if showsGrid, let plane = analysis.plane(.luma) {
                for level in plane.levels.reversed() {
                    let cell = CGFloat(level.blockFootprint) * scale
                    guard cell >= 10 else { continue }
                    let firstX = max(0, Int((visible.minX - frame.minX) / cell))
                    let lastX = min(level.blocksWide - 1, Int((visible.maxX - frame.minX) / cell))
                    let firstY = max(0, Int((visible.minY - frame.minY) / cell))
                    let lastY = min(level.blocksHigh - 1, Int((visible.maxY - frame.minY) / cell))
                    guard firstX <= lastX, firstY <= lastY, (lastX - firstX + 1) * (lastY - firstY + 1) < 30_000 else { continue }

                    var outlines = Path()
                    for blockY in firstY...lastY {
                        for blockX in firstX...lastX where level.modes[blockY * level.blocksWide + blockX] > 0 {
                            outlines.addRect(CGRect(x: frame.minX + CGFloat(blockX) * cell, y: frame.minY + CGFloat(blockY) * cell,
                                                    width: cell, height: cell).insetBy(dx: 0.5, dy: 0.5))
                        }
                    }
                    context.stroke(outlines, with: .color(Theme.level(level.level).opacity(0.9)),
                                   lineWidth: level.level == 0 ? 1 : 1.5)
                }
            }

            // The finest block that actually stores something under the pointer.
            if let probe = probes.first(where: { !$0.layers.isEmpty }) ?? probes.first {
                let cell = CGFloat(probe.footprint) * scale
                if cell >= 5 {
                    let rect = CGRect(x: frame.minX + CGFloat(probe.blockX) * cell, y: frame.minY + CGFloat(probe.blockY) * cell,
                                      width: cell, height: cell).intersection(frame)
                    context.stroke(Path(rect), with: .color(.black.opacity(0.6)), lineWidth: 3)
                    context.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
                }
            }
        }
        .frame(width: paneSize.width, height: paneSize.height)
    }
}

// MARK: - Split

/// Original on the left of a draggable divider, compressed on the right.
struct SplitComparison: View {
    @Environment(VaultModel.self) private var model
    let source: SourceImage
    let result: CompressionResult

    var body: some View {
        ViewportPane { frame, size in
            let dividerX = (model.splitFraction * size.width).rounded()

            ImageLayer(image: source.cgImage, frame: frame)

            ZStack(alignment: .topLeading) {
                // An opaque backing so the original never shows through the compressed side.
                Theme.canvas
                CompressedLayers(result: result, frame: frame, paneSize: size)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .mask(alignment: .topLeading) {
                Rectangle()
                    .frame(width: max(size.width - dividerX, 0), height: size.height)
                    .offset(x: dividerX)
            }

            PaneLabel(title: "Original", detail: originalDetail(source), alignment: .topLeading)
                .opacity(dividerX > 170 ? 1 : 0)
            PaneLabel(title: ".pixv", detail: Format.bytes(result.data.count), alignment: .topTrailing, tint: Theme.accent)
                .opacity(size.width - dividerX > 150 ? 1 : 0)

            SplitDivider(paneSize: size)
        }
    }
}

struct SplitDivider: View {
    @Environment(VaultModel.self) private var model
    let paneSize: CGSize
    @State private var isHovering = false
    @State private var dragOrigin: CGFloat?

    var body: some View {
        let x = (model.splitFraction * paneSize.width).rounded()

        ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 2)
                .shadow(color: .black.opacity(0.5), radius: 2)

            Circle()
                .fill(.white)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.45), radius: 5, y: 1)
                .overlay {
                    Image(systemName: "chevron.left.chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black.opacity(0.75))
                }
                .scaleEffect(isHovering || dragOrigin != nil ? 1.12 : 1)
                .animation(.snappy(duration: 0.15), value: isHovering)
        }
        .frame(width: 34, height: paneSize.height)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .pointerStyle(.columnResize)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let origin = dragOrigin ?? model.splitFraction
                    dragOrigin = origin
                    let moved = origin + value.translation.width / max(paneSize.width, 1)
                    model.splitFraction = min(max(moved, 0.02), 0.98)
                }
                .onEnded { _ in dragOrigin = nil }
        )
        .offset(x: x - 17)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel("Comparison divider")
    }
}

/// Names a pane's contents in one of its top corners.
struct PaneLabel: View {
    let title: String
    let detail: String
    let alignment: Alignment
    var tint: Color = .white

    var body: some View {
        CanvasBadge {
            HStack(spacing: 6) {
                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .allowsHitTesting(false)
    }
}

// MARK: - Chrome

/// Controls and readouts floating over the canvas: overlay legend, pointer readout, zoom.
struct CanvasChrome: View {
    @Environment(VaultModel.self) private var model
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    if hasLegend {
                        OverlayLegend()
                    }
                    if model.showsAdvanced {
                        PointerReadout()
                    }
                }
                Spacer(minLength: 10)
                zoomControls
            }
            .padding(12)
        }
    }

    /// The Patterns overlay has nothing to explain when the file stores no dictionary.
    private var hasLegend: Bool {
        guard model.result != nil else { return false }
        switch model.overlay {
        case .none: return false
        case .patterns: return model.selectedCodebook != nil
        case .blocks, .error: return true
        }
    }

    private var zoomControls: some View {
        CanvasBadge {
            HStack(spacing: 10) {
                Button {
                    model.viewport.zoom(by: 1 / 1.5)
                } label: {
                    Image(systemName: "minus")
                }
                .help("Zoom out (⌘−)")

                Text(verbatim: "\(Int((model.viewport.scale * displayScale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 44)
                    .help("Screen pixels per image pixel")

                Button {
                    model.viewport.zoom(by: 1.5)
                } label: {
                    Image(systemName: "plus")
                }
                .help("Zoom in (⌘+)")

                Divider().frame(height: 12)

                Button("Fit") { model.viewport.fit() }
                    .disabled(model.viewport.isFitted)
                    .help("Fit the image in the window (⌘0)")
                Button("1:1") { model.viewport.setScale(1 / displayScale) }
                    .help("One image pixel per screen pixel")
            }
            .buttonStyle(.plain)
        }
    }
}

/// Explains the colours of the active overlay.
struct OverlayLegend: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        @Bindable var model = model

        CanvasBadge {
            HStack(spacing: 12) {
                switch model.overlay {
                case .none:
                    EmptyView()
                case .blocks:
                    if let plane = model.result?.analysis.plane(.luma) {
                        ForEach(plane.levels, id: \.level) { level in
                            LegendSwatch(color: Theme.level(level.level), label: "\(level.blockFootprint) px blocks")
                        }
                        LegendSwatch(color: .clear, label: "base layer only")
                    }
                case .patterns:
                    if let codebook = model.selectedCodebook {
                        if let pattern = model.selectedPattern, pattern < codebook.usage.count {
                            LegendSwatch(color: Color(red: 1, green: 0.84, blue: 0.04),
                                         label: "Pattern \(pattern + 1) · \(Format.count(codebook.usage[pattern])) blocks")
                            Button("Clear") { model.selectedPattern = nil }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                        } else {
                            Image(systemName: "paintpalette")
                            Text("One colour per pattern in \(codebook.displayName). Click a block to trace its pattern.")
                        }
                    }
                case .error:
                    Text("Same")
                    LinearGradient(colors: [.black, .blue, Color(red: 0.9, green: 0, blue: 0.7), .yellow],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 110, height: 8)
                        .clipShape(Capsule())
                    Text("Different  ·  ×12")
                }

                if model.overlay == .blocks || model.overlay == .patterns {
                    Divider().frame(height: 12)
                    Slider(value: $model.overlayOpacity, in: 0.15...1)
                        .controlSize(.mini)
                        .frame(width: 70)
                        .help("Overlay opacity")
                }
            }
        }
    }
}

struct LegendSwatch: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.35)) }
                .frame(width: 11, height: 11)
            Text(label)
        }
    }
}

/// Says what the codec stores for the block under the pointer.
struct PointerReadout: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        if let hover = model.hover, model.result != nil {
            CanvasBadge {
                HStack(spacing: 10) {
                    Text(verbatim: "x \(hover.x)  y \(hover.y)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ForEach(model.hoverProbes.reversed()) { probe in
                        HStack(spacing: 4) {
                            Circle().fill(Theme.level(probe.level)).frame(width: 7, height: 7)
                            Text("\(probe.footprint) px")
                                .foregroundStyle(.secondary)
                            Text(description(of: probe))
                                .monospacedDigit()
                        }
                    }
                }
                .lineLimit(1)
            }
            .transition(.opacity)
        }
    }

    private func description(of probe: PIXVVisualizer.BlockProbe) -> String {
        guard !probe.layers.isEmpty else { return "—" }
        return probe.layers.map { "#\($0.pattern + 1)×\($0.gain > 0 ? "+" : "")\($0.gain)" }.joined(separator: " ")
    }
}
