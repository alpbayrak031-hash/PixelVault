import Foundation
import Testing
@testable import PixelVaultKit

@Suite("Codec")
struct CodecTests {
    @Test("Round trip preserves dimensions and stays faithful",
          arguments: [(1, 1), (3, 2), (7, 5), (16, 16), (33, 17), (64, 48), (130, 257), (320, 200), (513, 384)])
    func roundTrip(width: Int, height: Int) throws {
        let image = TestImages.scene(width: width, height: height)
        let encoded = try PixelVault.encode(image, quality: 75)
        let decoded = try PixelVault.decode(encoded.data)
        #expect(decoded.image.width == width)
        #expect(decoded.image.height == height)
        #expect(decoded.image.pixels.count == width * height * 4)
        #expect(!decoded.image.hasAlpha)
        let fidelity = ImageMetrics.psnr(image, decoded.image)
        // Halving chroma resolution bounds what a few-pixel image with a hard colour edge on
        // every pixel can reach; from 16 pixels up the result must be clearly faithful.
        #expect(fidelity > (min(width, height) >= 16 ? 30 : 18))
        if min(width, height) < 24 { #expect(decoded.analysis.patternCount == 0, "tiny images are stored as base layer only") }
    }

    @Test("Higher quality gives a more faithful, larger file")
    func qualityIsMonotonic() throws {
        let image = TestImages.scene(width: 640, height: 480)
        var previousSize = 0
        var previousFidelity = 0.0
        for quality in [10, 35, 60, 85, 100] {
            let encoded = try PixelVault.encode(image, quality: quality)
            let fidelity = ImageMetrics.psnr(image, try PixelVault.decode(encoded.data).image)
            #expect(encoded.data.count > previousSize)
            #expect(fidelity > previousFidelity)
            previousSize = encoded.data.count
            previousFidelity = fidelity
        }
        // The noisy quadrant caps what any lossy codec reaches; the rest must be near-transparent.
        #expect(previousFidelity > 36)
    }

    @Test("Encoding is deterministic")
    func deterministic() throws {
        let image = TestImages.scene(width: 400, height: 300)
        let first = try PixelVault.encode(image, quality: 60).data
        let second = try PixelVault.encode(image, quality: 60).data
        #expect(first == second)
    }

    @Test("A flat image costs almost nothing and decodes exactly")
    func flatImage() throws {
        let image = TestImages.solid(width: 512, height: 512, red: 128, green: 128, blue: 128)
        let encoded = try PixelVault.encode(image, quality: 60)
        let decoded = try PixelVault.decode(encoded.data)
        #expect(encoded.data.count < 400)
        #expect(decoded.image.pixels == image.pixels)
        #expect(decoded.analysis.colorModel == .grayscale)
    }

    @Test("Grayscale images drop their chroma planes")
    func grayscale() throws {
        let image = TestImages.gray(width: 256, height: 192)
        let decoded = try PixelVault.decode(try PixelVault.encode(image, quality: 70).data)
        #expect(decoded.analysis.colorModel == .grayscale)
        #expect(decoded.analysis.planes.map(\.kind) == [.luma])
        // No chroma was stored, so the output must be exactly neutral.
        for index in stride(from: 0, to: decoded.image.pixels.count, by: 4) {
            #expect(decoded.image.pixels[index] == decoded.image.pixels[index + 1])
            #expect(decoded.image.pixels[index + 1] == decoded.image.pixels[index + 2])
        }
        #expect(ImageMetrics.psnr(image, decoded.image) > 30)
    }

    @Test("Transparency survives")
    func alpha() throws {
        let image = TestImages.scene(width: 200, height: 160, alpha: true)
        let decoded = try PixelVault.decode(try PixelVault.encode(image, quality: 80).data)
        #expect(decoded.image.hasAlpha)
        #expect(decoded.analysis.planes.map(\.kind) == [.luma, .chromaBlue, .chromaRed, .alpha])

        var squaredError = 0.0
        for index in stride(from: 3, to: image.pixels.count, by: 4) {
            let difference = Double(image.pixels[index]) - Double(decoded.image.pixels[index])
            squaredError += difference * difference
        }
        let alphaError = squaredError / Double(image.pixelCount)
        #expect(alphaError < 30)
        // The fully transparent corner and fully opaque centre must stay that way.
        #expect(decoded.image.pixels[3] < 8)
        #expect(decoded.image.pixels[(80 * 200 + 100) * 4 + 3] > 247)
    }

    @Test("Analysis accounts for every byte and every block")
    func analysisIsConsistent() throws {
        let image = TestImages.scene(width: 480, height: 360)
        let encoded = try PixelVault.encode(image, quality: 65)
        let analysis = try PixelVault.decode(encoded.data).analysis

        #expect(analysis.fileSize == encoded.data.count)
        #expect(analysis.sizes.values.reduce(0, +) == encoded.data.count)
        #expect(analysis.quality == 65)

        for codebook in analysis.codebooks {
            #expect(codebook.patterns.count == codebook.patternCount * 16)
            #expect(codebook.usage.count == codebook.patternCount)
            // The encoder prunes unused patterns and sorts the rest by popularity.
            #expect(codebook.usage.allSatisfy { $0 > 0 })
            #expect(codebook.usage == codebook.usage.sorted(by: >))
        }
        for plane in analysis.planes {
            for level in plane.levels {
                #expect(level.modes.count == level.blockCount)
                #expect(level.blocksWide * 4 == plane.width >> level.level)
                #expect(level.modeHistogram().reduce(0, +) == level.blockCount)
                for stage in 0..<level.stages {
                    let book = try #require(analysis.codebook(id: plane.codebookIDs[stage]))
                    for block in 0..<level.blockCount {
                        if let pattern = level.patternIndex(block: block, stage: stage) {
                            #expect(pattern < book.patternCount)
                            #expect(level.gains[stage * level.blockCount + block] != 0)
                        }
                    }
                }
            }
        }
    }

    @Test("Header info can be read without decoding")
    func headerInfo() throws {
        let data = try PixelVault.encode(TestImages.scene(width: 123, height: 77), quality: 42).data
        let info = try PixelVault.readInfo(data)
        #expect(info.width == 123)
        #expect(info.height == 77)
        #expect(info.quality == 42)
        #expect(info.colorModel == .yCbCr420)
        #expect(!info.hasAlpha)
        #expect(PixelVault.isPixelVaultData(data))
        #expect(!PixelVault.isPixelVaultData(Data("PNG nope".utf8)))
    }

    @Test("Reduced-size decoding returns the pyramid's own smaller renditions")
    func previewDecoding() throws {
        // Odd dimensions, so rounding of the reduced size is exercised too.
        let image = TestImages.scene(width: 517, height: 389, alpha: true)
        let data = try PixelVault.encode(image, quality: 80).data
        let full = try PixelVault.decode(data).image

        // Asking for more pixels than exist returns the full image.
        #expect(try PixelVault.decodePreview(data, minimumLongSide: 10_000).pixels == full.pixels)

        // The long side halves to 258, 129, then 64; each request is the most that size can satisfy.
        for (request, divisor) in [(258, 2), (129, 4), (64, 8), (1, 8)] {
            let preview = try PixelVault.decodePreview(data, minimumLongSide: request)
            try #require(preview.width == (517 + divisor - 1) / divisor)
            try #require(preview.height == (389 + divisor - 1) / divisor)
            #expect(preview.hasAlpha)

            // It should look like the full decode averaged down by the same factor.
            var reference = [UInt8](repeating: 0, count: preview.pixels.count)
            for y in 0..<preview.height {
                for x in 0..<preview.width {
                    for channel in 0..<4 {
                        var sum = 0, count = 0
                        for sourceY in (y * divisor)..<min((y + 1) * divisor, full.height) {
                            for sourceX in (x * divisor)..<min((x + 1) * divisor, full.width) {
                                sum += Int(full.pixels[(sourceY * full.width + sourceX) * 4 + channel])
                                count += 1
                            }
                        }
                        reference[(y * preview.width + x) * 4 + channel] = UInt8((sum + count / 2) / count)
                    }
                }
            }
            let averaged = RGBAImage(width: preview.width, height: preview.height, pixels: reference, hasAlpha: true)
            #expect(ImageMetrics.psnr(preview, averaged) > 30, "1/\(divisor) preview should match the full decode")
        }
    }

    @Test("Images without a pyramid still produce a preview")
    func previewOfTinyImage() throws {
        let image = TestImages.scene(width: 12, height: 9)
        let data = try PixelVault.encode(image, quality: 60).data
        let preview = try PixelVault.decodePreview(data, minimumLongSide: 4)
        #expect(preview.width == 12 && preview.height == 9)
    }

    @Test("Block-wise upsampling matches the plane upsampler bit for bit")
    func upsamplerConsistency() {
        var generator = SplitMix64(seed: 11)
        for (width, height) in [(1, 1), (2, 3), (5, 4), (16, 9), (31, 32)] {
            let source = Plane(width: width, height: height,
                               data: (0..<(width * height)).map { _ in UInt8(generator.next() % 256) })
            let full = Pyramid.upsample(source)
            #expect(full.width == width * 2 && full.height == height * 2)
            var block = [Int32](repeating: 0, count: 16)
            // Only whole 4×4 blocks exist in real planes; walk every block origin that fits.
            for originY in stride(from: 0, to: full.height - 3, by: 4) {
                for originX in stride(from: 0, to: full.width - 3, by: 4) {
                    source.data.withUnsafeBufferPointer {
                        Pyramid.upsampledBlock($0.baseAddress!, width: width, height: height,
                                               originX: originX, originY: originY, into: &block)
                    }
                    for y in 0..<4 {
                        for x in 0..<4 {
                            #expect(Int32(full.data[(originY + y) * full.width + originX + x]) == block[y * 4 + x])
                        }
                    }
                }
            }
        }
    }

    @Test("Upsampling a flat plane leaves it flat")
    func upsamplerPreservesConstants() {
        for value: UInt8 in [0, 1, 127, 254, 255] {
            let plane = Plane(width: 9, height: 7, data: [UInt8](repeating: value, count: 63))
            #expect(Pyramid.upsample(plane).data.allSatisfy { $0 == value })
        }
    }

    @Test("Colour conversion round-trips within rounding error")
    func colourRoundTrip() {
        let image = TestImages.scene(width: 96, height: 64)
        let channels = ColorTransform.forward(image)
        let restored = ColorTransform.inverse(luma: channels.luma, chromaBlue: channels.chromaBlue,
                                              chromaRed: channels.chromaRed, alpha: nil, width: 96, height: 64)
        var worst = 0
        for index in image.pixels.indices {
            worst = max(worst, abs(Int(image.pixels[index]) - Int(restored.pixels[index])))
        }
        #expect(worst <= 2)

        // Primaries land where BT.601 full range says they should.
        let red = ColorTransform.forward(TestImages.solid(width: 4, height: 4, red: 255, green: 0, blue: 0))
        #expect(red.luma.data[0] == 76)
        #expect(red.chromaBlue.data[0] == 85)
        #expect(red.chromaRed.data[0] == 255)
    }

    @Test("Images round-trip through CGImage")
    func cgImageBridge() throws {
        for alpha in [false, true] {
            let image = TestImages.scene(width: 40, height: 30, alpha: alpha)
            let restored = try RGBAImage(cgImage: try image.makeCGImage())
            #expect(restored.width == 40 && restored.height == 30)
            #expect(restored.hasAlpha == alpha)
            if !alpha { #expect(restored.pixels == image.pixels) }
        }
        let png = try TestImages.scene(width: 40, height: 30).pngData()
        #expect(try RGBAImage(imageData: png).pixels == TestImages.scene(width: 40, height: 30).pixels)
    }
}

@Suite("Malformed input")
struct MalformedInputTests {
    private static let sample: [UInt8] = {
        let image = TestImages.scene(width: 96, height: 80, alpha: true)
        return [UInt8](try! PixelVault.encode(image, quality: 70).data)
    }()

    /// Rewrites the header checksum so damage reaches the parser instead of stopping at the CRC.
    private static func resealed(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count >= PIXVFormat.headerSize else { return bytes }
        var result = bytes
        let checksum = CRC32.checksum(result, range: PIXVFormat.headerSize..<result.count)
        for byte in 0..<4 { result[20 + byte] = UInt8(truncatingIfNeeded: checksum >> UInt32(8 * byte)) }
        return result
    }

    @Test("Rejects data that is not a .pixv file")
    func wrongSignature() {
        #expect(throws: PIXVError.notAPixelVaultFile) { try PixelVault.decode(Data()) }
        #expect(throws: PIXVError.notAPixelVaultFile) { try PixelVault.decode(Data("JFIF".utf8)) }
        #expect(throws: PIXVError.notAPixelVaultFile) { try PixelVault.decode(Data(repeating: 0, count: 4096)) }
    }

    @Test("Rejects a future major version")
    func futureVersion() {
        var bytes = Self.sample
        bytes[4] = 9
        #expect(throws: PIXVError.unsupportedVersion(major: 9, minor: 0)) { try PixelVault.decode(Data(bytes)) }
    }

    @Test("Detects damage through the checksum")
    func checksum() {
        var bytes = Self.sample
        bytes[bytes.count / 2] ^= 0x10
        #expect(throws: PIXVError.checksumMismatch) { try PixelVault.decode(Data(bytes)) }
    }

    @Test("Every truncation fails cleanly")
    func truncation() {
        for length in 0..<Self.sample.count {
            #expect(throws: PIXVError.self) { try PixelVault.decode(Data(Self.sample.prefix(length))) }
        }
    }

    @Test("Truncation with a valid checksum still fails cleanly")
    func resealedTruncation() {
        for length in stride(from: PIXVFormat.headerSize, to: Self.sample.count, by: 3) {
            // Must throw or (if the cut happens to fall on a boundary the format tolerates) decode — never trap.
            _ = try? PixelVault.decode(Data(Self.resealed(Array(Self.sample.prefix(length)))))
        }
    }

    @Test("Random damage never crashes the decoder")
    func fuzz() {
        var generator = SplitMix64(seed: 0xF022)
        var rejected = 0
        let trials = 3000
        for _ in 0..<trials {
            var bytes = Self.sample
            let flips = 1 + Int(generator.next() % 4)
            for _ in 0..<flips {
                // Leave the signature and version alone so the parser is actually exercised.
                let position = 6 + Int(generator.next() % UInt64(bytes.count - 6))
                bytes[position] = UInt8(truncatingIfNeeded: generator.next())
            }
            do {
                let decoded = try PixelVault.decode(Data(Self.resealed(bytes)))
                // Damage confined to pattern data can still parse; the result must be well formed.
                #expect(decoded.image.pixels.count == decoded.image.width * decoded.image.height * 4)
            } catch {
                rejected += 1
            }
        }
        // rANS streams end with a state check, so almost all damage is caught.
        #expect(rejected > trials * 9 / 10)
    }

    @Test("Absurd dimensions are refused before any allocation")
    func hostileDimensions() {
        var bytes = Self.sample
        for byte in 8..<16 { bytes[byte] = 0xFF }
        #expect(throws: PIXVError.invalidDimensions) { try PixelVault.decode(Data(Self.resealed(bytes))) }
    }
}
