import Accelerate
import Foundation

/// RGB ⇄ Y′CbCr (BT.601, full range) on vImage's fixed-point matrix kernels.
///
/// Coefficients are scaled by 2^14, the largest power of two that keeps every term inside
/// vImage's 16-bit matrix entries.
enum ColorTransform {
    private static let divisor: Int32 = 1 << 14
    private static let rounding: Int32 = 1 << 13
    private static let flags = vImage_Flags(kvImageNoFlags)

    struct Channels {
        var luma: Plane
        var chromaBlue: Plane
        var chromaRed: Plane
        var alpha: Plane?
    }

    /// Splits an RGBA image into full-resolution Y′, Cb, Cr (and alpha, when present) planes.
    static func forward(_ image: RGBAImage) -> Channels {
        let width = image.width, height = image.height
        var luma = Plane(uninitializedWidth: width, height: height)
        var chromaBlue = Plane(uninitializedWidth: width, height: height)
        var chromaRed = Plane(uninitializedWidth: width, height: height)
        var alpha = image.hasAlpha ? Plane(uninitializedWidth: width, height: height) : nil

        image.pixels.withUnsafeBufferPointer { pixels in
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pixels.baseAddress!),
                                       height: vImagePixelCount(height), width: vImagePixelCount(width),
                                       rowBytes: width * 4)

            func project(into plane: inout Plane, weights: [Int16], bias: Int32) {
                plane.data.withUnsafeMutableBufferPointer { samples in
                    var destination = vImage_Buffer(data: samples.baseAddress!, height: vImagePixelCount(height),
                                                    width: vImagePixelCount(width), rowBytes: width)
                    let status = vImageMatrixMultiply_ARGB8888ToPlanar8(&source, &destination, weights, divisor,
                                                                        nil, bias, flags)
                    precondition(status == kvImageNoError, "vImage colour projection failed")
                }
            }

            // Weights are listed in memory order: R, G, B, A.
            project(into: &luma, weights: [4899, 9617, 1868, 0], bias: rounding)
            project(into: &chromaBlue, weights: [-2765, -5427, 8192, 0], bias: 128 * divisor + rounding)
            project(into: &chromaRed, weights: [8192, -6860, -1332, 0], bias: 128 * divisor + rounding)

            alpha?.data.withUnsafeMutableBufferPointer { samples in
                var destination = vImage_Buffer(data: samples.baseAddress!, height: vImagePixelCount(height),
                                                width: vImagePixelCount(width), rowBytes: width)
                let status = vImageExtractChannel_ARGB8888(&source, &destination, 3, flags)
                precondition(status == kvImageNoError, "vImage alpha extraction failed")
            }
        }
        return Channels(luma: luma, chromaBlue: chromaBlue, chromaRed: chromaRed, alpha: alpha)
    }

    /// Recombines planes into RGBA. Planes may be larger than `width × height` (codec padding);
    /// only their top-left region is used. Pass `nil` chroma for a grayscale image.
    static func inverse(luma: Plane, chromaBlue: Plane?, chromaRed: Plane?, alpha: Plane?,
                        width: Int, height: Int) -> RGBAImage {
        var pixels = [UInt8].uninitialized(width * height * 4)

        func view(_ plane: Plane, _ pointer: UnsafePointer<UInt8>) -> vImage_Buffer {
            vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pointer), height: vImagePixelCount(height),
                          width: vImagePixelCount(width), rowBytes: plane.width)
        }

        func interleave(red: inout vImage_Buffer, green: inout vImage_Buffer, blue: inout vImage_Buffer) {
            pixels.withUnsafeMutableBufferPointer { output in
                var destination = vImage_Buffer(data: output.baseAddress!, height: vImagePixelCount(height),
                                                width: vImagePixelCount(width), rowBytes: width * 4)
                let status: vImage_Error
                if let alpha {
                    status = alpha.data.withUnsafeBufferPointer { alphaSamples in
                        var alphaView = view(alpha, alphaSamples.baseAddress!)
                        // The "ARGB" kernel writes its four sources in argument order, giving R, G, B, A.
                        return vImageConvert_Planar8toARGB8888(&red, &green, &blue, &alphaView, &destination, flags)
                    }
                } else {
                    // Likewise "BGRX" written as (R, G, B) yields R, G, B, 255.
                    status = vImageConvert_Planar8ToBGRX8888(&red, &green, &blue, 255, &destination, flags)
                }
                precondition(status == kvImageNoError, "vImage interleave failed")
            }
        }

        luma.data.withUnsafeBufferPointer { lumaSamples in
            var lumaView = view(luma, lumaSamples.baseAddress!)

            guard let chromaBlue, let chromaRed else {
                var green = lumaView, blue = lumaView
                interleave(red: &lumaView, green: &green, blue: &blue)
                return
            }

            var red = [UInt8].uninitialized(width * height)
            var green = [UInt8].uninitialized(width * height)
            var blue = [UInt8].uninitialized(width * height)

            chromaBlue.data.withUnsafeBufferPointer { blueSamples in
                chromaRed.data.withUnsafeBufferPointer { redSamples in
                    red.withUnsafeMutableBufferPointer { redOut in
                        green.withUnsafeMutableBufferPointer { greenOut in
                            blue.withUnsafeMutableBufferPointer { blueOut in
                                var cbView = view(chromaBlue, blueSamples.baseAddress!)
                                var crView = view(chromaRed, redSamples.baseAddress!)
                                func output(_ pointer: UnsafeMutablePointer<UInt8>) -> vImage_Buffer {
                                    vImage_Buffer(data: pointer, height: vImagePixelCount(height),
                                                  width: vImagePixelCount(width), rowBytes: width)
                                }
                                var redView = output(redOut.baseAddress!)
                                var greenView = output(greenOut.baseAddress!)
                                var blueView = output(blueOut.baseAddress!)

                                // vImage treats pixels as row vectors: entry [source * 3 + destination].
                                let matrix: [Int16] = [
                                    16384, 16384, 16384,   // Y′  → R, G, B
                                    0, -5638, 29032,       // Cb  → R, G, B
                                    22970, -11700, 0,      // Cr  → R, G, B
                                ]
                                let preBias: [Int16] = [0, -128, -128]
                                let postBias: [Int32] = [rounding, rounding, rounding]

                                withUnsafePointer(to: &lumaView) { y in
                                    withUnsafePointer(to: &cbView) { cb in
                                        withUnsafePointer(to: &crView) { cr in
                                            withUnsafePointer(to: &redView) { r in
                                                withUnsafePointer(to: &greenView) { g in
                                                    withUnsafePointer(to: &blueView) { b in
                                                        var sources: [UnsafePointer<vImage_Buffer>?] = [y, cb, cr]
                                                        var destinations: [UnsafePointer<vImage_Buffer>?] = [r, g, b]
                                                        let status = vImageMatrixMultiply_Planar8(
                                                            &sources, &destinations, 3, 3, matrix, divisor,
                                                            preBias, postBias, flags)
                                                        precondition(status == kvImageNoError, "vImage colour matrix failed")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                interleave(red: &redView, green: &greenView, blue: &blueView)
                            }
                        }
                    }
                }
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels, hasAlpha: alpha != nil)
    }
}
