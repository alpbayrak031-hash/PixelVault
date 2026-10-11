import Foundation

/// Renders a file's internal structure as images and answers "what is under this pixel?".
///
/// Maps are produced at one pixel per finest-level block, so they stay tiny; display them
/// scaled by `cellSize` with nearest-neighbour sampling to line up with the image.
public enum PIXVVisualizer {
    /// A structure overlay and how to place it over the image.
    public struct Map: Sendable {
        public let image: RGBAImage
        /// Image pixels covered by one map pixel, along each axis.
        public let cellSize: Int
    }

    /// What one pyramid level stores for the block covering a given pixel.
    public struct BlockProbe: Sendable, Identifiable {
        public struct Layer: Sendable {
            public let codebookID: Int
            public let pattern: Int
            public let gain: Int
        }

        public let plane: PIXVPlaneKind
        public let level: Int
        public let blockX: Int
        public let blockY: Int
        /// Side length of the block in image pixels.
        public let footprint: Int
        /// Patterns stacked on this block, first stage first. Empty when the block is inherited.
        public let layers: [Layer]

        public var id: Int { level }
    }

    // MARK: Palette

    /// One colour per pyramid level, finest first: detail runs warm, coarse structure cool.
    public static let levelColors: [(red: UInt8, green: UInt8, blue: UInt8)] = [
        (255, 105, 97), (255, 199, 64), (72, 212, 150), (64, 156, 255), (176, 122, 255), (255, 122, 214),
    ]

    public static func levelColor(_ level: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        levelColors[min(level, levelColors.count - 1)]
    }

    /// A stable, well-spread colour for a pattern index.
    public static func patternColor(_ index: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        // Golden-ratio hue stepping keeps neighbouring indices far apart on the wheel.
        let hue = (Double(index) * 0.618_033_988_749_895).truncatingRemainder(dividingBy: 1)
        let saturation = 0.62 + 0.3 * Double((index / 7) % 3) / 2
        return hsv(hue: hue, saturation: saturation, value: 1)
    }

    private static func hsv(hue: Double, saturation: Double, value: Double) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let sector = hue * 6
        let chroma = value * saturation
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: (r, g, b) = (chroma, x, 0)
        case 1: (r, g, b) = (x, chroma, 0)
        case 2: (r, g, b) = (0, chroma, x)
        case 3: (r, g, b) = (0, x, chroma)
        case 4: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let offset = value - chroma
        return (UInt8((r + offset) * 255), UInt8((g + offset) * 255), UInt8((b + offset) * 255))
    }

    // MARK: Maps

    /// Fills the cells a block covers in a finest-level-resolution map.
    private static func paint(_ pixels: inout [UInt8], mapWidth: Int, mapHeight: Int, level: Int,
                              blockX: Int, blockY: Int,
                              color: (red: UInt8, green: UInt8, blue: UInt8), alpha: UInt8) {
        let span = 1 << level
        let startX = blockX * span, startY = blockY * span
        for y in startY..<min(startY + span, mapHeight) {
            var index = (y * mapWidth + startX) * 4
            for _ in startX..<min(startX + span, mapWidth) {
                pixels[index] = color.red
                pixels[index + 1] = color.green
                pixels[index + 2] = color.blue
                pixels[index + 3] = alpha
                index += 4
            }
        }
    }

    /// How the image is chunked: every block is coloured by the finest pyramid level that
    /// adds patterns there, and more opaque the more patterns it stacks. Regions the base
    /// layer alone carries stay clear.
    public static func structureMap(_ analysis: PIXVAnalysis, plane kind: PIXVPlaneKind = .luma) -> Map? {
        guard let plane = analysis.plane(kind), let finest = plane.levels.first else { return nil }
        let mapWidth = finest.blocksWide, mapHeight = finest.blocksHigh
        var pixels = [UInt8](repeating: 0, count: mapWidth * mapHeight * 4)

        // Coarse to fine, so finer blocks draw over the coarse ones they refine.
        for level in plane.levels.reversed() {
            let color = levelColor(level.level)
            for blockY in 0..<level.blocksHigh {
                for blockX in 0..<level.blocksWide {
                    let mode = Int(level.modes[blockY * level.blocksWide + blockX])
                    guard mode > 0 else { continue }
                    paint(&pixels, mapWidth: mapWidth, mapHeight: mapHeight, level: level.level,
                          blockX: blockX, blockY: blockY, color: color, alpha: UInt8(min(235, 125 + 35 * mode)))
                }
            }
        }
        return Map(image: RGBAImage(width: mapWidth, height: mapHeight, pixels: pixels, hasAlpha: true),
                   cellSize: finest.blockFootprint)
    }

    /// Where one dictionary is used: each block is tinted by the pattern it takes from
    /// `codebookID`. With `highlight` set, only blocks using that pattern light up and the
    /// rest of the image is dimmed.
    public static func patternMap(_ analysis: PIXVAnalysis, codebookID: Int, highlight: Int? = nil) -> Map? {
        let users = analysis.planes.filter { $0.codebookIDs.contains(codebookID) && !$0.levels.isEmpty }
        guard let first = users.first, let finest = first.levels.first else { return nil }
        let mapWidth = finest.blocksWide, mapHeight = finest.blocksHigh
        var pixels = [UInt8](repeating: 0, count: mapWidth * mapHeight * 4)

        if highlight != nil {
            for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 150 }
        }

        for plane in users {
            guard let stage = plane.codebookIDs.firstIndex(of: codebookID) else { continue }
            for level in plane.levels.reversed() {
                for blockY in 0..<level.blocksHigh {
                    for blockX in 0..<level.blocksWide {
                        guard let pattern = level.patternIndex(block: blockY * level.blocksWide + blockX, stage: stage)
                        else { continue }
                        if let highlight {
                            guard pattern == highlight else { continue }
                            paint(&pixels, mapWidth: mapWidth, mapHeight: mapHeight, level: level.level,
                                  blockX: blockX, blockY: blockY, color: (255, 214, 10), alpha: 240)
                        } else {
                            paint(&pixels, mapWidth: mapWidth, mapHeight: mapHeight, level: level.level,
                                  blockX: blockX, blockY: blockY, color: patternColor(pattern), alpha: 205)
                        }
                    }
                }
            }
        }
        return Map(image: RGBAImage(width: mapWidth, height: mapHeight, pixels: pixels, hasAlpha: true),
                   cellSize: finest.blockFootprint)
    }

    /// Per-pixel error between two images as a heat map: black where they agree, through
    /// blue and magenta to yellow where they differ most. `amplification` scales the error
    /// before colouring so small differences become visible.
    public static func errorMap(original: RGBAImage, decoded: RGBAImage, amplification: Double = 12) -> RGBAImage {
        precondition(original.width == decoded.width && original.height == decoded.height)
        let width = original.width, height = original.height
        var pixels = [UInt8].uninitialized(width * height * 4)

        // 256-entry colour ramp.
        var ramp = [UInt8](repeating: 0, count: 256 * 3)
        for step in 0..<256 {
            let t = Double(step) / 255
            ramp[step * 3] = UInt8(255 * min(1, max(0, 1.6 * t - 0.25)))
            ramp[step * 3 + 1] = UInt8(255 * min(1, max(0, 2.2 * t - 1.1)))
            ramp[step * 3 + 2] = UInt8(255 * min(1, max(0, t < 0.5 ? 2.4 * t : 1.7 - 1.9 * t)))
        }
        let gain = Int32((amplification * 256 / 3).rounded())

        original.pixels.withUnsafeBufferPointer { first in
            decoded.pixels.withUnsafeBufferPointer { second in
                pixels.withUnsafeMutableBufferPointer { output in
                    ramp.withUnsafeBufferPointer { colors in
                        Parallel.stripes(height, grain: 32) { rows in
                            for index in (rows.lowerBound * width)..<(rows.upperBound * width) {
                                let base = index * 4
                                let difference = abs(Int32(first[base]) - Int32(second[base]))
                                    + abs(Int32(first[base + 1]) - Int32(second[base + 1]))
                                    + abs(Int32(first[base + 2]) - Int32(second[base + 2]))
                                let step = Int(min(255, (difference * gain) >> 8))
                                output[base] = colors[step * 3]
                                output[base + 1] = colors[step * 3 + 1]
                                output[base + 2] = colors[step * 3 + 2]
                                output[base + 3] = 255
                            }
                        }
                    }
                }
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels, hasAlpha: false)
    }

    // MARK: Probing

    /// The blocks of `plane` that cover image pixel `(x, y)`, finest level first.
    public static func probe(_ analysis: PIXVAnalysis, plane kind: PIXVPlaneKind = .luma, x: Int, y: Int) -> [BlockProbe] {
        guard let plane = analysis.plane(kind), x >= 0, y >= 0, x < analysis.width, y < analysis.height else { return [] }
        return plane.levels.map { level in
            let blockX = min(x / level.blockFootprint, level.blocksWide - 1)
            let blockY = min(y / level.blockFootprint, level.blocksHigh - 1)
            let block = blockY * level.blocksWide + blockX
            let layers = (0..<Int(level.modes[block])).map { stage in
                BlockProbe.Layer(codebookID: plane.codebookIDs[stage],
                                 pattern: Int(level.indices[stage * level.blockCount + block]),
                                 gain: Int(level.gains[stage * level.blockCount + block]))
            }
            return BlockProbe(plane: kind, level: level.level, blockX: blockX, blockY: blockY,
                              footprint: level.blockFootprint, layers: layers)
        }
    }

    /// A pattern as sixteen display intensities in `0…1`, mid-grey meaning "no change".
    /// Each pattern is stretched to its own peak so its shape is visible.
    public static func tile(_ codebook: PIXVAnalysis.Codebook, pattern: Int) -> [Double] {
        let values = codebook.pattern(pattern)
        let peak = Double(values.map { abs(Int($0)) }.max() ?? 0)
        guard peak > 0 else { return [Double](repeating: 0.5, count: 16) }
        return values.map { 0.5 + 0.5 * Double($0) / peak }
    }
}
