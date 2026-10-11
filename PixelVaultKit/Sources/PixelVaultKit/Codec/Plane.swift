import Foundation

/// An 8-bit RGBA image with straight (non-premultiplied) alpha, in sRGB.
public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes, rows top to bottom, no row padding.
    public var pixels: [UInt8]
    /// False when every alpha value is 255.
    public var hasAlpha: Bool

    public init(width: Int, height: Int, pixels: [UInt8], hasAlpha: Bool) {
        precondition(width > 0 && height > 0, "image must not be empty")
        precondition(pixels.count == width * height * 4, "pixel buffer does not match dimensions")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.hasAlpha = hasAlpha
    }

    public var pixelCount: Int { width * height }
}

/// A single 8-bit channel.
struct Plane: Sendable {
    var width: Int
    var height: Int
    var data: [UInt8]

    init(width: Int, height: Int, data: [UInt8]) {
        precondition(data.count == width * height)
        self.width = width
        self.height = height
        self.data = data
    }

    /// A plane whose samples the caller will overwrite in full.
    init(uninitializedWidth width: Int, height: Int) {
        self.width = width
        self.height = height
        data = .uninitialized(width * height)
    }

    /// Extends the plane to `newWidth × newHeight` by repeating its last column and row.
    func padded(toWidth newWidth: Int, height newHeight: Int) -> Plane {
        if newWidth == width && newHeight == height { return self }
        precondition(newWidth >= width && newHeight >= height)
        var result = Plane(uninitializedWidth: newWidth, height: newHeight)
        data.withUnsafeBufferPointer { source in
            result.data.withUnsafeMutableBufferPointer { destination in
                let src = source.baseAddress!, dst = destination.baseAddress!
                for y in 0..<newHeight {
                    let sourceRow = src + min(y, height - 1) * width
                    let row = dst + y * newWidth
                    row.update(from: sourceRow, count: width)
                    if newWidth > width {
                        (row + width).update(repeating: sourceRow[width - 1], count: newWidth - width)
                    }
                }
            }
        }
        return result
    }

    /// The top-left `newWidth × newHeight` region.
    func cropped(toWidth newWidth: Int, height newHeight: Int) -> Plane {
        if newWidth == width && newHeight == height { return self }
        var result = Plane(uninitializedWidth: newWidth, height: newHeight)
        data.withUnsafeBufferPointer { source in
            result.data.withUnsafeMutableBufferPointer { destination in
                for y in 0..<newHeight {
                    (destination.baseAddress! + y * newWidth).update(from: source.baseAddress! + y * width, count: newWidth)
                }
            }
        }
        return result
    }
}

/// The resolution pyramid both ends of the codec walk.
///
/// `upsample` is normative: decoders must reproduce it bit for bit, because each level's
/// patterns are residuals against the upsampled level above. `downsample` is the encoder's
/// choice of analysis filter and is not part of the format.
enum Pyramid {
    // Catmull-Rom taps for a quarter-sample offset, scaled by 128. Output sample 2i sits at
    // source position i − ¼ and sample 2i + 1 at i + ¼, so the two share one mirrored kernel.

    /// Sample at `i − ¼` from sources `i−2, i−1, i, i+1`.
    @inline(__always)
    private static func lowerTap(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32) -> Int32 {
        29 &* b &+ 111 &* c &- 3 &* a &- 9 &* d
    }

    /// Sample at `i + ¼` from sources `i−1, i, i+1, i+2`.
    @inline(__always)
    private static func upperTap(_ b: Int32, _ c: Int32, _ d: Int32, _ e: Int32) -> Int32 {
        111 &* c &+ 29 &* d &- 9 &* b &- 3 &* e
    }

    /// 2× bicubic (Catmull-Rom) interpolation, separable, in integer arithmetic:
    ///
    ///     H[y][2x]   = (lowerTap(S[y][x−2…x+1]) + 4) >> 3          horizontal, 4 fractional bits
    ///     H[y][2x+1] = (upperTap(S[y][x−1…x+2]) + 4) >> 3
    ///     O[2y][X]   = clamp((lowerTap(H[y−2…y+1][X]) + 1024) >> 11, 0, 255)
    ///     O[2y+1][X] = clamp((upperTap(H[y−1…y+2][X]) + 1024) >> 11, 0, 255)
    ///
    /// Source indices are clamped to the plane; shifts are arithmetic.
    static func upsample(_ source: Plane) -> Plane {
        let width = source.width, height = source.height
        let outputWidth = width * 2
        var result = Plane(uninitializedWidth: outputWidth, height: height * 2)
        var horizontal = [Int16].uninitialized(outputWidth * height)

        source.data.withUnsafeBufferPointer { sourceBuffer in
            horizontal.withUnsafeMutableBufferPointer { horizontalBuffer in
                let src = sourceBuffer.baseAddress!, mid = horizontalBuffer.baseAddress!
                Parallel.stripes(height, grain: 16) { rows in
                    for y in rows {
                        let row = src + y * width
                        let out = mid + y * outputWidth

                        func emit(_ x: Int, _ a: Int, _ b: Int, _ d: Int, _ e: Int) {
                            let va = Int32(row[a]), vb = Int32(row[b]), vc = Int32(row[x])
                            let vd = Int32(row[d]), ve = Int32(row[e])
                            out[2 * x] = Int16(truncatingIfNeeded: (lowerTap(va, vb, vc, vd) &+ 4) >> 3)
                            out[2 * x + 1] = Int16(truncatingIfNeeded: (upperTap(vb, vc, vd, ve) &+ 4) >> 3)
                        }

                        // Clamped borders, then a branch-free interior the compiler can vectorise.
                        let interior = 2..<max(2, width - 2)
                        for x in 0..<width where !interior.contains(x) {
                            emit(x, max(x - 2, 0), max(x - 1, 0), min(x + 1, width - 1), min(x + 2, width - 1))
                        }
                        for x in interior {
                            let va = Int32(row[x - 2]), vb = Int32(row[x - 1]), vc = Int32(row[x])
                            let vd = Int32(row[x + 1]), ve = Int32(row[x + 2])
                            out[2 * x] = Int16(truncatingIfNeeded: (lowerTap(va, vb, vc, vd) &+ 4) >> 3)
                            out[2 * x + 1] = Int16(truncatingIfNeeded: (upperTap(vb, vc, vd, ve) &+ 4) >> 3)
                        }
                    }
                }
            }
        }

        horizontal.withUnsafeBufferPointer { horizontalBuffer in
            result.data.withUnsafeMutableBufferPointer { resultBuffer in
                let mid = horizontalBuffer.baseAddress!, dst = resultBuffer.baseAddress!
                Parallel.stripes(height, grain: 16) { rows in
                    for y in rows {
                        let rowA = mid + max(y - 2, 0) * outputWidth
                        let rowB = mid + max(y - 1, 0) * outputWidth
                        let rowC = mid + y * outputWidth
                        let rowD = mid + min(y + 1, height - 1) * outputWidth
                        let rowE = mid + min(y + 2, height - 1) * outputWidth
                        let upper = dst + (2 * y) * outputWidth
                        let lower = upper + outputWidth
                        for x in 0..<outputWidth {
                            let va = Int32(rowA[x]), vb = Int32(rowB[x]), vc = Int32(rowC[x])
                            let vd = Int32(rowD[x]), ve = Int32(rowE[x])
                            let first = (lowerTap(va, vb, vc, vd) &+ 1024) >> 11
                            let second = (upperTap(vb, vc, vd, ve) &+ 1024) >> 11
                            upper[x] = UInt8(truncatingIfNeeded: max(0, min(255, first)))
                            lower[x] = UInt8(truncatingIfNeeded: max(0, min(255, second)))
                        }
                    }
                }
            }
        }
        return result
    }

    /// One 4×4 block of the upsampled plane, bit-identical to `upsample`, for callers that
    /// need scattered blocks rather than the whole plane. `originX`/`originY` are the block's
    /// top-left corner in the upsampled plane and must be multiples of 4.
    static func upsampledBlock(_ source: UnsafePointer<UInt8>, width: Int, height: Int,
                               originX: Int, originY: Int, into block: UnsafeMutablePointer<Int32>) {
        let sourceX = originX >> 1, sourceY = originY >> 1

        // The block's two source columns reach two samples either side, likewise its rows.
        withUnsafeTemporaryAllocation(of: Int32.self, capacity: 24) { horizontal in
            for row in 0..<6 {
                let line = source + max(0, min(height - 1, sourceY - 2 + row)) * width
                func sample(_ column: Int) -> Int32 { Int32(line[max(0, min(width - 1, column))]) }
                for pair in 0..<2 {
                    let x = sourceX + pair
                    let a = sample(x - 2), b = sample(x - 1), c = sample(x), d = sample(x + 1), e = sample(x + 2)
                    horizontal[row * 4 + pair * 2] = (lowerTap(a, b, c, d) &+ 4) >> 3
                    horizontal[row * 4 + pair * 2 + 1] = (upperTap(b, c, d, e) &+ 4) >> 3
                }
            }
            for pair in 0..<2 {
                for x in 0..<4 {
                    let a = horizontal[pair * 4 + x], b = horizontal[(pair + 1) * 4 + x]
                    let c = horizontal[(pair + 2) * 4 + x], d = horizontal[(pair + 3) * 4 + x]
                    let e = horizontal[(pair + 4) * 4 + x]
                    block[(pair * 2) * 4 + x] = max(0, min(255, (lowerTap(a, b, c, d) &+ 1024) >> 11))
                    block[(pair * 2 + 1) * 4 + x] = max(0, min(255, (upperTap(b, c, d, e) &+ 1024) >> 11))
                }
            }
        }
    }

    /// 2×2 box average. Dimensions must be even.
    static func downsample(_ source: Plane) -> Plane {
        precondition(source.width % 2 == 0 && source.height % 2 == 0)
        let width = source.width / 2, height = source.height / 2
        var result = Plane(uninitializedWidth: width, height: height)
        source.data.withUnsafeBufferPointer { sourceBuffer in
            result.data.withUnsafeMutableBufferPointer { resultBuffer in
                let src = sourceBuffer.baseAddress!, dst = resultBuffer.baseAddress!
                Parallel.stripes(height, grain: 32) { rows in
                    for y in rows {
                        let top = src + (2 * y) * source.width
                        let bottom = top + source.width
                        let out = dst + y * width
                        for x in 0..<width {
                            let sum = UInt16(top[2 * x]) &+ UInt16(top[2 * x + 1])
                                &+ UInt16(bottom[2 * x]) &+ UInt16(bottom[2 * x + 1]) &+ 2
                            out[x] = UInt8(truncatingIfNeeded: sum >> 2)
                        }
                    }
                }
            }
        }
        return result
    }
}
