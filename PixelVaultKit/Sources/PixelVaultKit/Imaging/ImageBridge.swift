import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Bridges between `RGBAImage` and the system's image types and file formats.
extension RGBAImage {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Converts any `CGImage` to 8-bit sRGB with straight alpha. vImage performs the colour
    /// match and un-premultiplication, writing straight into the pixel array.
    public init(cgImage: CGImage) throws {
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { throw PIXVError.imageDecodingFailed }
        guard var format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: Self.sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            renderingIntent: .defaultIntent)
        else { throw PIXVError.imageDecodingFailed }

        var pixels = [UInt8].uninitialized(width * height * 4)
        let status = pixels.withUnsafeMutableBufferPointer { storage -> vImage_Error in
            var buffer = vImage_Buffer(data: storage.baseAddress!, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
            return vImageBuffer_InitWithCGImage(&buffer, &format, nil, cgImage, vImage_Flags(kvImageNoAllocate))
        }
        guard status == kvImageNoError else { throw PIXVError.imageDecodingFailed }

        var hasAlpha = false
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            break
        default:
            // Many files carry an alpha channel that is fully opaque; don't spend a plane on it.
            hasAlpha = pixels.withUnsafeBufferPointer { storage in
                var index = 3
                while index < storage.count {
                    if storage[index] != 255 { return true }
                    index += 4
                }
                return false
            }
        }
        self.init(width: width, height: height, pixels: pixels, hasAlpha: hasAlpha)
    }

    /// Wraps the pixels in a `CGImage` (the data is copied once).
    public func makeCGImage() throws -> CGImage {
        let alpha: CGImageAlphaInfo = hasAlpha ? .last : .noneSkipLast
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: Self.sRGB,
                                  bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw PIXVError.imageEncodingFailed }
        return image
    }

    /// Decodes an image file (JPEG, PNG, HEIC, TIFF, …) with its EXIF orientation applied.
    public init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PIXVError.imageDecodingFailed
        }
        try self.init(imageSource: source)
    }

    /// Decodes encoded image data with its EXIF orientation applied.
    public init(imageData: Data) throws {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw PIXVError.imageDecodingFailed
        }
        try self.init(imageSource: source)
    }

    private init(imageSource source: CGImageSource) throws {
        guard CGImageSourceGetCount(source) > 0 else { throw PIXVError.imageDecodingFailed }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            // A full-size "thumbnail" is ImageIO's way of handing back an upright copy.
            let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight, 1),
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else { throw PIXVError.imageDecodingFailed }
        try self.init(cgImage: image)
    }

    /// Encodes the image as PNG.
    public func pngData() throws -> Data {
        let image = try makeCGImage()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PIXVError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PIXVError.imageEncodingFailed }
        return data as Data
    }
}

/// Objective fidelity measures between an original and its reconstruction.
public enum ImageMetrics {
    /// Mean squared error over the R, G and B channels.
    public static func meanSquaredError(_ a: RGBAImage, _ b: RGBAImage) -> Double {
        precondition(a.width == b.width && a.height == b.height, "images must match in size")
        let width = a.width, height = a.height
        var partials = [UInt64](repeating: 0, count: height)
        a.pixels.withUnsafeBufferPointer { first in
            b.pixels.withUnsafeBufferPointer { second in
                partials.withUnsafeMutableBufferPointer { sums in
                    Parallel.stripes(height, grain: 32) { rows in
                        for y in rows {
                            var sum: UInt64 = 0
                            var index = y * width * 4
                            for _ in 0..<width {
                                for channel in 0..<3 {
                                    let difference = Int(first[index + channel]) - Int(second[index + channel])
                                    sum &+= UInt64(difference * difference)
                                }
                                index += 4
                            }
                            sums[y] = sum
                        }
                    }
                }
            }
        }
        return Double(partials.reduce(0, +)) / Double(width * height * 3)
    }

    /// Peak signal-to-noise ratio in decibels; infinite for identical images.
    public static func psnr(_ a: RGBAImage, _ b: RGBAImage) -> Double {
        let error = meanSquaredError(a, b)
        return error == 0 ? .infinity : 10 * log10(255.0 * 255.0 / error)
    }
}
