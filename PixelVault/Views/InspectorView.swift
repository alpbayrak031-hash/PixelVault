import PixelVaultKit
import SwiftUI

/// The numbers: how much smaller, how fast, how faithful, and where the bytes went.
struct InspectorView: View {
    @Environment(VaultModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let result = model.result {
                    SummaryCard(result: result, source: model.source)
                    if model.source != nil {
                        QualityCard()
                    }
                    SpeedCard(result: result)
                    if let psnr = result.psnr {
                        FidelityCard(psnr: psnr, analysis: result.analysis)
                    }
                    BitstreamCard(analysis: result.analysis)
                    StructureCard(analysis: result.analysis)
                } else {
                    ContentUnavailableView("No Image", systemImage: "chart.bar.xaxis",
                                           description: Text("Open an image to see how it compresses."))
                        .padding(.top, 80)
                }
            }
            .padding(12)
        }
        .background(Theme.panel)
    }
}

// MARK: - Summary

struct SummaryCard: View {
    let result: CompressionResult
    let source: SourceImage?

    var body: some View {
        Card(title: "Compression", symbol: "arrow.down.right.and.arrow.up.left") {
            if let source {
                let reference = source.fileSize ?? source.rawSize
                let ratio = Double(reference) / Double(max(result.data.count, 1))

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.ratio(ratio))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(ratio >= 1 ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.orange))
                        .contentTransition(.numericText())
                    Text(ratio >= 1 ? "smaller" : "the size")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .animation(.snappy(duration: 0.2), value: result.data.count)

                VStack(spacing: 7) {
                    SizeBar(label: source.fileSize == nil ? "Uncompressed" : source.formatName, bytes: reference,
                            fraction: 1, style: AnyShapeStyle(.white.opacity(0.3)))
                    SizeBar(label: ".pixv", bytes: result.data.count,
                            fraction: min(1, Double(result.data.count) / Double(max(reference, 1))),
                            style: AnyShapeStyle(Theme.brand))
                }

                if source.fileSize != nil {
                    Text(rawComparison(rawSize: source.rawSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                let raw = result.image.pixelCount * (result.image.hasAlpha ? 4 : 3)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.bytes(result.data.count))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.brand)
                    Text(".pixv")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("\(rawComparison(rawSize: raw)) Written at quality \(result.analysis.quality).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The fixed cost of a file's framing can outweigh a few hundred bytes of pixels.
    private func rawComparison(rawSize: Int) -> String {
        let size = max(result.data.count, 1)
        return rawSize >= size
            ? "\(Format.ratio(Double(rawSize) / Double(size))) smaller than the \(Format.bytes(rawSize)) of raw pixels."
            : "No smaller than the \(Format.bytes(rawSize)) of raw pixels — an image this tiny is mostly file overhead."
    }
}

struct SizeBar: View {
    let label: String
    let bytes: Int
    let fraction: Double
    let style: AnyShapeStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text(Format.bytes(bytes)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            GeometryReader { proxy in
                Capsule()
                    .fill(.white.opacity(0.06))
                    .overlay(alignment: .leading) {
                        Capsule().fill(style).frame(width: max(4, proxy.size.width * fraction))
                    }
            }
            .frame(height: 6)
            .animation(.snappy(duration: 0.25), value: fraction)
        }
    }
}

// MARK: - Quality

struct QualityCard: View {
    @Environment(VaultModel.self) private var model

    private static let presets: [(name: String, quality: Double)] = [("Compact", 30), ("Balanced", 60), ("Detailed", 85)]

    var body: some View {
        @Bindable var model = model

        Card(title: "Quality", symbol: "dial.medium") {
            HStack {
                Slider(value: $model.quality, in: 1...100, step: 1)
                    .accessibilityLabel("Quality")
                Text("\(Int(model.quality))")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }

            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.name) { preset in
                    Button(preset.name) { model.quality = preset.quality }
                        .buttonStyle(.bordered)
                        .tint(Int(model.quality) == Int(preset.quality) ? Theme.accent : nil)
                }
            }
            .controlSize(.small)

            Text("Re-encodes as you drag. Higher quality stacks more patterns on detailed blocks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Speed

struct SpeedCard: View {
    let result: CompressionResult

    var body: some View {
        let megapixels = Double(result.image.pixelCount) / 1_000_000

        Card(title: "Speed", symbol: "bolt.fill") {
            HStack(spacing: 10) {
                if let encode = result.encodeTimings {
                    Stat(value: Format.milliseconds(encode.total), label: "Encode",
                         detail: throughput(megapixels, encode.total))
                }
                Stat(value: Format.milliseconds(result.decodeTimings.total), label: "Decode",
                     detail: throughput(megapixels, result.decodeTimings.total))
            }

            if let encode = result.encodeTimings {
                SegmentBar(segments: [
                    ("Analysis", encode.analysis, Theme.accentCool),
                    ("Learning", encode.training, Color(red: 1.0, green: 0.76, blue: 0.30)),
                    ("Matching", encode.matching, Theme.accent),
                    ("Entropy", encode.entropyCoding, Color(red: 0.36, green: 0.80, blue: 0.56)),
                ], format: Format.milliseconds)
            }
        }
    }

    private func throughput(_ megapixels: Double, _ milliseconds: Double) -> String {
        guard milliseconds > 0 else { return "" }
        return String(format: "%.0f MP/s", megapixels / milliseconds * 1000)
    }
}

struct Stat: View {
    let value: String
    let label: String
    var detail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A proportional bar with a legend underneath.
struct SegmentBar: View {
    let segments: [(name: String, value: Double, color: Color)]
    let format: (Double) -> String

    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.value }, .leastNonzeroMagnitude)

        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(segments, id: \.name) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(0, (proxy.size.width - CGFloat(segments.count - 1) * 1.5) * segment.value / total))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      spacing: 4) {
                ForEach(segments, id: \.name) { segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.color).frame(width: 7, height: 7)
                        Text(segment.name).foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Text(format(segment.value)).monospacedDigit()
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Fidelity

struct FidelityCard: View {
    let psnr: Double
    let analysis: PIXVAnalysis

    private var verdict: (text: String, color: Color) {
        switch psnr {
        case 42...: ("Near-lossless", Color(red: 0.36, green: 0.80, blue: 0.56))
        case 38..<42: ("Excellent", Color(red: 0.36, green: 0.80, blue: 0.56))
        case 34..<38: ("Good", Theme.accentCool)
        case 30..<34: ("Fair", Color(red: 1.0, green: 0.76, blue: 0.30))
        default: ("Rough", .orange)
        }
    }

    var body: some View {
        Card(title: "Fidelity", symbol: "eye") {
            HStack(spacing: 10) {
                Stat(value: psnr.isFinite ? String(format: "%.1f dB", psnr) : "Exact", label: "PSNR")
                Stat(value: String(format: "%.2f", analysis.bitsPerPixel), label: "Bits per pixel")
            }
            HStack(spacing: 6) {
                Circle().fill(verdict.color).frame(width: 7, height: 7)
                Text(verdict.text).fontWeight(.medium)
                Text("· lossy; fine texture softens first")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}

// MARK: - Bitstream

struct BitstreamCard: View {
    let analysis: PIXVAnalysis

    var body: some View {
        Card(title: "Inside the file", symbol: "shippingbox") {
            SegmentBar(segments: PIXVSizeCategory.allCases
                .map { ($0.displayName, Double(analysis.sizes[$0] ?? 0), Theme.category($0)) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 },
                format: { Format.bytes(Int($0)) })
        }
    }
}

// MARK: - Structure

struct StructureCard: View {
    let analysis: PIXVAnalysis

    var body: some View {
        Card(title: "Block structure", symbol: "square.grid.3x3.square") {
            if let luma = analysis.plane(.luma), !luma.levels.isEmpty {
                VStack(spacing: 7) {
                    ForEach(luma.levels, id: \.level) { level in
                        let coded = level.modes.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
                        let fraction = Double(coded) / Double(max(level.blockCount, 1))
                        HStack(spacing: 8) {
                            Text("\(level.blockFootprint) px")
                                .frame(width: 36, alignment: .leading)
                                .monospacedDigit()
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(.white.opacity(0.06))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Theme.level(level.level))
                                            .frame(width: max(3, proxy.size.width * fraction))
                                    }
                            }
                            .frame(height: 6)
                            Text(Format.percent(fraction))
                                .frame(width: 34, alignment: .trailing)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .help("\(Format.count(coded)) of \(Format.count(level.blockCount)) blocks at this size carry patterns")
                    }
                }
                Text("Share of blocks at each size that carry patterns. The rest are inherited from the coarser level beneath.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Stored as a base layer only — too small to need patterns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack(spacing: 10) {
                Stat(value: Format.count(analysis.patternCount), label: "Patterns")
                Stat(value: "\(analysis.codebooks.count)", label: "Dictionaries")
            }
        }
    }
}
