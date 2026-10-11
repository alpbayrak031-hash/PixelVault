import Foundation

/// The internal structure of a `.pixv` file: its dictionaries, how each plane is chunked
/// into blocks, which pattern every block uses, and where the bytes went.
public struct PIXVAnalysis: Sendable {
    /// One pattern dictionary.
    public struct Codebook: Sendable, Identifiable {
        public let id: Int
        public let role: PIXVCodebookRole
        /// 0 for the first pattern applied to a block, 1 for the refinement on top of it, and so on.
        public let stage: Int
        public let patternCount: Int
        /// `patternCount × 16` signed samples, each pattern a row-major 4×4 block.
        public let patterns: [Int8]
        /// How many blocks use each pattern. Patterns are stored most-used first.
        public let usage: [Int]

        public var totalUsage: Int { usage.reduce(0, +) }

        public var displayName: String {
            "\(role == .luma ? "Luma" : "Chroma") · stage \(stage + 1)"
        }

        public func pattern(_ index: Int) -> ArraySlice<Int8> {
            patterns[(index * 16)..<((index + 1) * 16)]
        }
    }

    /// One pyramid level of one plane.
    public struct Level: Sendable {
        /// 0 is the plane's full resolution; each step up halves it.
        public let level: Int
        public let blocksWide: Int
        public let blocksHigh: Int
        /// Side length, in image pixels, of the square one block covers.
        public let blockFootprint: Int
        public let stages: Int
        /// Patterns stacked on each block; 0 means the block is inherited from the level above.
        public let modes: [UInt8]
        /// `[stage * blockCount + block]`, meaningful where `modes[block] > stage`.
        public let indices: [UInt16]
        public let gains: [Int16]

        public var blockCount: Int { blocksWide * blocksHigh }

        /// The pattern a block uses at `stage`, or `nil` if it has none.
        public func patternIndex(block: Int, stage: Int) -> Int? {
            guard stage < stages, modes[block] > stage else { return nil }
            return Int(indices[stage * blockCount + block])
        }

        /// Number of blocks using exactly `count` patterns, for `count` in `0...stages`.
        public func modeHistogram() -> [Int] {
            var histogram = [Int](repeating: 0, count: stages + 1)
            for mode in modes { histogram[Int(mode)] += 1 }
            return histogram
        }
    }

    public struct PlaneInfo: Sendable {
        public let kind: PIXVPlaneKind
        /// Plane dimensions in samples, including codec padding.
        public let width: Int
        public let height: Int
        /// Image pixels per plane sample along each axis (2 for subsampled chroma).
        public let subsampling: Int
        public let baseStep: Int
        public let gainStep: Double
        /// Dictionary used by each stage.
        public let codebookIDs: [Int]
        /// Index 0 is the finest level.
        public let levels: [Level]
        /// Dimensions of the base layer the pyramid starts from.
        public let baseWidth: Int
        public let baseHeight: Int
    }

    public let width: Int
    public let height: Int
    public let colorModel: PIXVColorModel
    public let hasAlpha: Bool
    public let quality: Int
    public let planes: [PlaneInfo]
    public let codebooks: [Codebook]
    /// Bytes spent per category; the values sum to `fileSize`.
    public let sizes: [PIXVSizeCategory: Int]
    public let fileSize: Int

    public func plane(_ kind: PIXVPlaneKind) -> PlaneInfo? {
        planes.first { $0.kind == kind }
    }

    public func codebook(id: Int) -> Codebook? {
        codebooks.first { $0.id == id }
    }

    /// Total number of patterns across all dictionaries.
    public var patternCount: Int {
        codebooks.reduce(0) { $0 + $1.patternCount }
    }

    /// Bits per image pixel.
    public var bitsPerPixel: Double {
        Double(fileSize * 8) / Double(width * height)
    }

    init(_ image: CodedImage, sizes: Container.Sizes, fileSize: Int) {
        width = image.width
        height = image.height
        colorModel = image.colorModel
        hasAlpha = image.hasAlpha
        quality = image.quality
        self.sizes = sizes
        self.fileSize = fileSize

        let usage = image.patternUsage()
        codebooks = image.codebooks.map {
            Codebook(id: $0.id, role: $0.role, stage: $0.stage, patternCount: $0.book.count,
                     patterns: $0.book.stored, usage: usage[$0.id] ?? [])
        }

        let geometry = image.geometry
        planes = image.planes.map { plane in
            let size = geometry.planeSize(for: plane.kind)
            let subsampling = plane.kind.isChroma ? 2 : 1
            return PlaneInfo(
                kind: plane.kind, width: size.width, height: size.height, subsampling: subsampling,
                baseStep: plane.baseStep, gainStep: Double(plane.gainStep), codebookIDs: plane.codebookIDs,
                levels: plane.levels.enumerated().map { level, coding in
                    Level(level: level, blocksWide: coding.blocksWide, blocksHigh: coding.blocksHigh,
                          blockFootprint: (PIXVFormat.blockSize << level) * subsampling, stages: coding.stages,
                          modes: coding.modes, indices: coding.indices, gains: coding.gains)
                },
                baseWidth: plane.base.width, baseHeight: plane.base.height)
        }
    }
}
