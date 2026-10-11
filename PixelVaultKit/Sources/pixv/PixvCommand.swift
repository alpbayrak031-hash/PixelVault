import Foundation
import PixelVaultKit

/// pixv — command-line front end for the PixelVault codec.
@main
struct PixvCommand {
    static let usage = """
        usage:
          pixv encode <image> <output.pixv> [--quality 1-100]
          pixv decode <input.pixv> <output.png>
          pixv info   <input.pixv>
          pixv bench  <image> [--quality 1-100[,…]] [--runs N]
          pixv psnr   <image-or-pixv> <image-or-pixv>
        """

    var arguments: [String]

    static func main() {
        var command = PixvCommand(arguments: Array(CommandLine.arguments.dropFirst()))
        do {
            try command.run()
        } catch {
            fail("pixv: \(error.localizedDescription)")
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    /// Removes `name <value>` from the arguments and returns the value.
    mutating func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    mutating func run() throws {
        guard let verb = arguments.first else { Self.fail(Self.usage) }
        arguments.removeFirst()

        switch verb {
        case "encode":
            let quality = option("--quality").flatMap(Int.init) ?? PixelVault.defaultQuality
            guard arguments.count == 2 else { Self.fail(Self.usage) }
            let image = try RGBAImage(contentsOf: URL(fileURLWithPath: arguments[0]))
            let result = try PixelVault.encode(image, quality: quality)
            try result.data.write(to: URL(fileURLWithPath: arguments[1]))
            print("\(arguments[1]): \(bytes(result.data.count)) in \(format(result.timings.total)) ms")

        case "decode":
            guard arguments.count == 2 else { Self.fail(Self.usage) }
            let result = try PixelVault.decode(try Data(contentsOf: URL(fileURLWithPath: arguments[0])))
            try result.image.pngData().write(to: URL(fileURLWithPath: arguments[1]))
            print("\(arguments[1]): \(result.image.width)×\(result.image.height) in \(format(result.timings.total)) ms")

        case "info":
            guard arguments.count == 1 else { Self.fail(Self.usage) }
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
            describe(try PixelVault.decode(data).analysis)

        case "bench":
            let qualities = (option("--quality") ?? "\(PixelVault.defaultQuality)")
                .split(separator: ",").compactMap { Int($0) }
            let runs = max(1, option("--runs").flatMap(Int.init) ?? 3)
            guard arguments.count == 1 else { Self.fail(Self.usage) }
            try bench(URL(fileURLWithPath: arguments[0]), qualities: qualities, runs: runs)

        case "psnr":
            guard arguments.count == 2 else { Self.fail(Self.usage) }
            let first = try load(URL(fileURLWithPath: arguments[0]))
            let second = try load(URL(fileURLWithPath: arguments[1]))
            guard first.width == second.width, first.height == second.height else {
                Self.fail("pixv: images differ in size")
            }
            print("\(format(ImageMetrics.psnr(first, second), 2)) dB")

        default:
            Self.fail(Self.usage)
        }
    }

    /// Loads either a `.pixv` file or any image format the system can read.
    func load(_ url: URL) throws -> RGBAImage {
        let data = try Data(contentsOf: url)
        return PixelVault.isPixelVaultData(data) ? try PixelVault.decode(data).image : try RGBAImage(imageData: data)
    }

    func bench(_ url: URL, qualities: [Int], runs: Int) throws {
        let sourceSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let image = try RGBAImage(contentsOf: url)
        let megapixels = Double(image.pixelCount) / 1e6
        print("\(url.lastPathComponent): \(image.width)×\(image.height) (\(format(megapixels)) MP), source \(bytes(sourceSize))")

        for quality in qualities {
            // Keep the fastest of several runs: the first pays for cold caches and page faults.
            var encoded = try PixelVault.encode(image, quality: quality)
            var decoded = try PixelVault.decode(encoded.data)
            for _ in 1..<runs {
                let encodeRun = try PixelVault.encode(image, quality: quality)
                let decodeRun = try PixelVault.decode(encodeRun.data)
                if encodeRun.timings.total < encoded.timings.total { encoded = encodeRun }
                if decodeRun.timings.total < decoded.timings.total { decoded = decodeRun }
            }
            let size = encoded.data.count
            let encode = encoded.timings, decode = decoded.timings
            print("\nquality \(quality): \(bytes(size))  (\(format(Double(sourceSize) / Double(size), 2))x smaller than source, "
                + "\(format(Double(size * 8) / Double(image.pixelCount), 3)) bpp)  "
                + "PSNR \(format(ImageMetrics.psnr(image, decoded.image), 2)) dB")
            print("  encode \(format(encode.total)) ms (analysis \(format(encode.analysis)), training \(format(encode.training)), "
                + "matching \(format(encode.matching)), entropy \(format(encode.entropyCoding)))  "
                + "\(format(megapixels / encode.total * 1000, 0)) MP/s")
            print("  decode \(format(decode.total)) ms (entropy \(format(decode.entropyDecoding)), "
                + "reconstruction \(format(decode.reconstruction)))  \(format(megapixels / decode.total * 1000, 0)) MP/s")
            describe(decoded.analysis)
        }
    }

    func describe(_ analysis: PIXVAnalysis) {
        print("  \(analysis.width)×\(analysis.height)  \(analysis.colorModel)  quality \(analysis.quality)  "
            + "\(format(analysis.bitsPerPixel, 3)) bpp")
        for codebook in analysis.codebooks {
            print("  dictionary \(codebook.id): \(codebook.displayName), \(codebook.patternCount) patterns, "
                + "\(codebook.totalUsage) uses")
        }
        for plane in analysis.planes {
            for level in plane.levels.reversed() {
                let shares = level.modeHistogram().map { format(100 * Double($0) / Double(level.blockCount), 0) + "%" }
                print("  \(plane.kind.displayName) level \(level.level) (\(level.blockFootprint) px blocks, "
                    + "\(level.blockCount)): patterns per block 0…\(level.stages) = \(shares.joined(separator: " "))")
            }
        }
        for category in PIXVSizeCategory.allCases {
            let size = analysis.sizes[category] ?? 0
            print("  \(category.displayName.padding(toLength: 20, withPad: " ", startingAt: 0)) "
                + "\(bytes(size))  \(format(100 * Double(size) / Double(analysis.fileSize)))%")
        }
    }

    func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    func format(_ value: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}
