import Foundation
import Testing
@testable import PixelVaultKit

@Suite("Visualizer")
struct VisualizerTests {
    private static let image = TestImages.scene(width: 320, height: 240)
    private static let decoded = try! PixelVault.decode(try! PixelVault.encode(image, quality: 60).data)

    @Test("Structure map has one cell per finest block")
    func structureMap() throws {
        let analysis = Self.decoded.analysis
        let luma = try #require(analysis.plane(.luma))
        let finest = try #require(luma.levels.first)
        let map = try #require(PIXVVisualizer.structureMap(analysis))
        #expect(map.image.width == finest.blocksWide && map.image.height == finest.blocksHigh)
        #expect(map.cellSize == 4)

        // A cell is painted exactly when some level stores patterns for the block covering it.
        for blockY in 0..<finest.blocksHigh {
            for blockX in 0..<finest.blocksWide {
                let coded = luma.levels.contains { level in
                    level.modes[(blockY >> level.level) * level.blocksWide + (blockX >> level.level)] > 0
                }
                let alpha = map.image.pixels[(blockY * map.image.width + blockX) * 4 + 3]
                #expect((alpha > 0) == coded)
            }
        }
    }

    @Test("Highlighting a pattern marks exactly the blocks that use it")
    func patternHighlight() throws {
        let analysis = Self.decoded.analysis
        let luma = try #require(analysis.plane(.luma))
        let codebook = try #require(analysis.codebooks.first { $0.role == .luma && $0.stage == 0 })
        let map = try #require(PIXVVisualizer.patternMap(analysis, codebookID: codebook.id, highlight: 0))

        for blockY in 0..<map.image.height {
            for blockX in 0..<map.image.width {
                let used = luma.levels.contains { level in
                    level.patternIndex(block: (blockY >> level.level) * level.blocksWide + (blockX >> level.level),
                                       stage: 0) == 0
                }
                let index = (blockY * map.image.width + blockX) * 4
                let isHighlighted = map.image.pixels[index] == 255 && map.image.pixels[index + 1] == 214
                #expect(isHighlighted == used)
            }
        }
        #expect(PIXVVisualizer.patternMap(analysis, codebookID: 999) == nil)
    }

    @Test("Probing a pixel reports what each level stores there")
    func probe() throws {
        let analysis = Self.decoded.analysis
        let luma = try #require(analysis.plane(.luma))
        for (x, y) in [(0, 0), (37, 121), (319, 239), (160, 120)] {
            let probes = PIXVVisualizer.probe(analysis, x: x, y: y)
            #expect(probes.map(\.level) == luma.levels.map(\.level))
            for (probe, level) in zip(probes, luma.levels) {
                #expect(probe.footprint == level.blockFootprint)
                #expect(probe.blockX == x / level.blockFootprint && probe.blockY == y / level.blockFootprint)
                let block = probe.blockY * level.blocksWide + probe.blockX
                #expect(probe.layers.count == Int(level.modes[block]))
                for (stage, layer) in probe.layers.enumerated() {
                    #expect(layer.pattern == level.patternIndex(block: block, stage: stage))
                    #expect(layer.codebookID == luma.codebookIDs[stage])
                }
            }
        }
        #expect(PIXVVisualizer.probe(analysis, x: -1, y: 0).isEmpty)
        #expect(PIXVVisualizer.probe(analysis, x: 320, y: 0).isEmpty)
    }

    @Test("Error map is black where images agree and lit where they differ")
    func errorMap() {
        let same = PIXVVisualizer.errorMap(original: Self.image, decoded: Self.image)
        #expect(stride(from: 0, to: same.pixels.count, by: 4).allSatisfy {
            same.pixels[$0] == 0 && same.pixels[$0 + 1] == 0 && same.pixels[$0 + 2] == 0
        })
        let differing = PIXVVisualizer.errorMap(original: Self.image, decoded: Self.decoded.image)
        #expect(differing.pixels.contains { $0 != 0 && $0 != 255 })
    }

    @Test("Tiles stay in display range")
    func tiles() throws {
        for codebook in Self.decoded.analysis.codebooks {
            for pattern in 0..<min(codebook.patternCount, 32) {
                let tile = PIXVVisualizer.tile(codebook, pattern: pattern)
                #expect(tile.count == 16)
                #expect(tile.allSatisfy { (0...1).contains($0) })
                // Stretched to its own peak, so some sample reaches an extreme.
                #expect(tile.contains { $0 == 0 || $0 == 1 })
            }
        }
    }
}
