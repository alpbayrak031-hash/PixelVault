import Foundation
@testable import PixelVaultKit

/// Deterministic synthetic images that exercise smooth, textured and hard-edged content.
enum TestImages {
    /// Gradients, a sinusoidal texture, noise and solid rectangles in one frame.
    static func scene(width: Int, height: Int, seed: UInt64 = 7, alpha: Bool = false) -> RGBAImage {
        var generator = SplitMix64(seed: seed)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(max(1, width - 1)), v = Double(y) / Double(max(1, height - 1))
                var red = 40 + 180 * u
                var green = 60 + 150 * v
                var blue = 200 - 120 * u * v

                // Texture in the lower-left quadrant.
                if u < 0.5 && v > 0.5 {
                    let wave = sin(Double(x) * 0.9) * cos(Double(y) * 0.7)
                    red += 40 * wave; green += 40 * wave; blue += 25 * wave
                }
                // Noise in the lower-right quadrant.
                if u >= 0.5 && v > 0.5 {
                    let noise = Double(generator.next() % 61) - 30
                    red += noise; green += noise; blue += noise
                }
                // A hard-edged rectangle and a diagonal line.
                if (0.15...0.35).contains(u) && (0.1...0.3).contains(v) { red = 250; green = 245; blue = 235 }
                if abs(x - y) < 2 { red = 15; green = 15; blue = 20 }

                let index = (y * width + x) * 4
                pixels[index] = UInt8(max(0, min(255, red)))
                pixels[index + 1] = UInt8(max(0, min(255, green)))
                pixels[index + 2] = UInt8(max(0, min(255, blue)))
                if alpha {
                    // A soft-edged disc of opacity.
                    let distance = ((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)).squareRoot()
                    pixels[index + 3] = UInt8(max(0, min(255, (0.48 - distance) * 2000)))
                }
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels, hasAlpha: alpha)
    }

    static func gray(width: Int, height: Int) -> RGBAImage {
        var image = scene(width: width, height: height)
        for index in stride(from: 0, to: image.pixels.count, by: 4) {
            let luma = image.pixels[index + 1]
            image.pixels[index] = luma
            image.pixels[index + 2] = luma
        }
        return image
    }

    static func solid(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = red; pixels[index + 1] = green; pixels[index + 2] = blue
        }
        return RGBAImage(width: width, height: height, pixels: pixels, hasAlpha: false)
    }
}
