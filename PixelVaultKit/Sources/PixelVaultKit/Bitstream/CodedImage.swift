import Foundation

/// Which planes a pattern dictionary serves.
public enum PIXVCodebookRole: UInt8, Sendable, Hashable {
    case luma = 0
    case chroma = 1
}

/// What a run of bytes in a `.pixv` file is spent on.
public enum PIXVSizeCategory: String, Sendable, CaseIterable, Identifiable {
    /// File header, section framing, per-plane parameters and length prefixes.
    case container
    /// Pattern dictionaries and their usage statistics.
    case dictionary
    /// The lowest-resolution image each pyramid starts from.
    case baseLayer
    /// Per-block stage counts.
    case blockModes
    /// Which pattern each block uses.
    case patternIndices
    /// How strongly each pattern is applied.
    case gains

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .container: "Container"
        case .dictionary: "Dictionary"
        case .baseLayer: "Base layer"
        case .blockModes: "Block map"
        case .patternIndices: "Pattern indices"
        case .gains: "Pattern gains"
        }
    }
}

/// A pattern dictionary as carried in the file.
struct CodedCodebook: Sendable {
    var id: Int
    var role: PIXVCodebookRole
    var stage: Int
    var book: PatternBook
}

/// One plane's coded content.
struct CodedPlane: Sendable {
    var kind: PIXVPlaneKind
    /// Quantiser step of the base layer.
    var baseStep: Int
    /// Gain quantiser step in half units (`gainStep = gainStepHalves / 2`).
    var gainStepHalves: Int
    /// Dictionary used by each stage, by `CodedCodebook.id`.
    var codebookIDs: [Int]
    /// Quantised base-layer samples.
    var base: Plane
    /// Pattern-coded levels; index 0 is full plane resolution.
    var levels: [LevelCoding]

    var gainStep: Float { Float(gainStepHalves) / 2 }
    var stages: Int { codebookIDs.count }
}

/// Everything a `.pixv` file says, parsed but not yet turned back into pixels.
/// The encoder produces one; `Container` serialises and parses it; `Reconstructor` renders it.
struct CodedImage: Sendable {
    var width: Int
    var height: Int
    var colorModel: PIXVColorModel
    var hasAlpha: Bool
    var lumaLevels: Int
    var quality: Int
    var codebooks: [CodedCodebook]
    var planes: [CodedPlane]

    var geometry: PIXVGeometry {
        PIXVGeometry(width: width, height: height, lumaLevels: lumaLevels)
    }

    /// The plane kinds this image must contain, in file order.
    var expectedPlaneKinds: [PIXVPlaneKind] {
        var kinds: [PIXVPlaneKind] = colorModel == .grayscale ? [.luma] : [.luma, .chromaBlue, .chromaRed]
        if hasAlpha { kinds.append(.alpha) }
        return kinds
    }

    func codebook(id: Int) -> CodedCodebook? {
        codebooks.first { $0.id == id }
    }

    /// How often each pattern of each dictionary is used, keyed by codebook id.
    func patternUsage() -> [Int: [Int]] {
        var usage: [Int: [Int]] = [:]
        for codebook in codebooks {
            usage[codebook.id] = [Int](repeating: 0, count: codebook.book.count)
        }
        for plane in planes {
            for coding in plane.levels {
                for stage in 0..<min(coding.stages, plane.codebookIDs.count) {
                    let id = plane.codebookIDs[stage]
                    guard var counts = usage[id] else { continue }
                    let base = stage * coding.blockCount
                    for block in 0..<coding.blockCount where coding.modes[block] > stage {
                        counts[Int(coding.indices[base + block])] += 1
                    }
                    usage[id] = counts
                }
            }
        }
        return usage
    }
}

extension Parallel {
    /// Concurrent `map` over `0..<count`.
    static func map<T>(_ count: Int, _ transform: (Int) -> T) -> [T] {
        var results = [T?](repeating: nil, count: count)
        results.withUnsafeMutableBufferPointer { buffer in
            forEach(count) { buffer[$0] = transform($0) }
        }
        return results.map { $0! }
    }
}
