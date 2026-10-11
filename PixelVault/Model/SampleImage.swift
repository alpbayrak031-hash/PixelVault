import CoreGraphics
import Foundation
import PixelVaultKit

/// A built-in demo picture, drawn rather than bundled: a dusk landscape with a smooth sky,
/// layered ridges, grainy foreground and rippled water — one region for each way the codec
/// can treat a block.
enum SampleImage {
    static let name = "Sample Landscape"

    static func make(width: Int = 2400, height: Int = 1600) throws -> SourceImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw PIXVError.imageEncodingFailed }

        let w = CGFloat(width), h = CGFloat(height)
        // Draw with a top-left origin.
        context.translateBy(x: 0, y: h)
        context.scaleBy(x: 1, y: -1)

        func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [red, green, blue, alpha])!
        }

        // Sky.
        let sky = CGGradient(colorsSpace: space, colors: [
            color(0.07, 0.08, 0.22), color(0.33, 0.22, 0.48), color(0.93, 0.50, 0.42), color(1.0, 0.80, 0.55),
        ] as CFArray, locations: [0, 0.38, 0.72, 1])!
        context.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: h * 0.62), options: [.drawsAfterEndLocation])

        // Sun and its glow.
        let sun = CGPoint(x: w * 0.68, y: h * 0.50)
        let glow = CGGradient(colorsSpace: space, colors: [
            color(1, 0.96, 0.82, 0.95), color(1, 0.78, 0.50, 0.35), color(1, 0.6, 0.4, 0),
        ] as CFArray, locations: [0, 0.25, 1])!
        context.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: w * 0.30, options: [])
        context.setFillColor(color(1, 0.97, 0.88))
        context.fillEllipse(in: CGRect(x: sun.x - w * 0.028, y: sun.y - w * 0.028, width: w * 0.056, height: w * 0.056))

        // Stars in the upper sky.
        var generator = SplitMix64(seed: 2024)
        func random() -> CGFloat { CGFloat(generator.next() % 100_000) / 100_000 }
        for _ in 0..<420 {
            let x = random() * w, y = random() * random() * h * 0.42
            let radius = 0.6 + random() * 1.6
            context.setFillColor(color(1, 1, 1, 0.25 + 0.6 * random() * (1 - y / (h * 0.45))))
            context.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius))
        }

        // Ridges, far to near: each is a sum of sines, darker and rougher than the last.
        let ridges: [(base: CGFloat, amplitude: CGFloat, color: CGColor, roughness: CGFloat)] = [
            (0.50, 0.060, color(0.46, 0.32, 0.52), 0.2),
            (0.56, 0.075, color(0.30, 0.22, 0.42), 0.5),
            (0.63, 0.090, color(0.17, 0.14, 0.30), 0.9),
            (0.72, 0.070, color(0.08, 0.08, 0.17), 1.4),
        ]
        for (index, ridge) in ridges.enumerated() {
            let phase = CGFloat(index) * 1.9
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: h))
            var x: CGFloat = 0
            while x <= w {
                let t = x / w
                var y = sin(t * 5.1 + phase) * 0.55 + sin(t * 11.3 + phase * 2.1) * 0.28 + sin(t * 23.7 + phase * 0.7) * 0.12
                y += sin(t * 71 + phase * 3) * 0.035 * ridge.roughness + sin(t * 163 + phase) * 0.02 * ridge.roughness
                path.addLine(to: CGPoint(x: x, y: h * (ridge.base - ridge.amplitude * y)))
                x += 2
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(ridge.color)
            context.fillPath()
        }

        // Water: a darkened reflection of the sky with horizontal ripples.
        let waterTop = h * 0.80
        let water = CGGradient(colorsSpace: space, colors: [
            color(0.40, 0.26, 0.40), color(0.10, 0.10, 0.24), color(0.03, 0.04, 0.10),
        ] as CFArray, locations: [0, 0.4, 1])!
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: waterTop, width: w, height: h - waterTop))
        context.drawLinearGradient(water, start: CGPoint(x: 0, y: waterTop), end: CGPoint(x: 0, y: h), options: [])
        for _ in 0..<900 {
            let y = waterTop + random() * random() * (h - waterTop)
            let depth = (y - waterTop) / (h - waterTop)
            let length = (20 + random() * 160) * (0.4 + depth)
            // Ripples cluster under the sun, like its reflection.
            let x = sun.x + (random() - 0.5) * w * (0.15 + 1.2 * random())
            context.setFillColor(color(1, 0.80, 0.60, 0.05 + 0.30 * random() * (1 - abs(x - sun.x) / w)))
            context.fill(CGRect(x: x - length / 2, y: y, width: length, height: 1 + depth * 2.5))
        }
        context.restoreGState()

        guard let rendered = context.makeImage() else { throw PIXVError.imageEncodingFailed }
        var image = try RGBAImage(cgImage: rendered)

        // Film grain over the foreground ridge and water, so there is real texture to code.
        var grain = SplitMix64(seed: 77)
        let grainTop = Int(h * 0.60)
        image.pixels.withUnsafeMutableBufferPointer { pixels in
            for y in grainTop..<height {
                let strength = 4 + 14 * Double(y - grainTop) / Double(height - grainTop)
                for x in 0..<width {
                    let noise = (Double(grain.next() % 2001) / 1000 - 1) * strength
                    let index = (y * width + x) * 4
                    for channel in 0..<3 {
                        pixels[index + channel] = UInt8(max(0, min(255, Double(pixels[index + channel]) + noise)))
                    }
                }
            }
        }

        // Report the size a lossless PNG of the same pixels would take, as the "original".
        let png = try image.pngData()
        return SourceImage(name: name, formatName: "PNG", fileSize: png.count, image: image,
                           cgImage: try image.makeCGImage())
    }
}

/// Deterministic generator so the sample is identical on every launch.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
