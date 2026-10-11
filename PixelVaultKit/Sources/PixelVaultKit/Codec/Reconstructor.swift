import Foundation

/// Turns a parsed `CodedImage` back into pixels. This is the normative decoding process:
/// the encoder runs the same plane reconstruction to stay in lockstep with decoders.
enum Reconstructor {
    /// Expands the quantised base layer to sample values.
    static func dequantizedBase(_ plane: CodedPlane) -> Plane {
        guard plane.baseStep > 1 else { return plane.base }
        var result = plane.base
        let step = plane.baseStep
        for index in result.data.indices {
            result.data[index] = UInt8(min(255, Int(result.data[index]) * step))
        }
        return result
    }

    /// Walks a plane's pyramid from the base layer up to full plane resolution:
    /// upsample, add that level's patterns, repeat.
    static func reconstruct(_ plane: CodedPlane, books: [PatternBook]) -> Plane {
        var current = dequantizedBase(plane)
        for level in plane.levels.indices.reversed() {
            let prediction = Pyramid.upsample(current)
            current = LevelCodec.reconstruct(prediction: prediction, coding: plane.levels[level], books: books,
                                             gainStep: plane.gainStep)
        }
        return current
    }

    static func render(_ image: CodedImage) throws -> RGBAImage {
        let geometry = image.geometry
        guard image.planes.map(\.kind) == image.expectedPlaneKinds else {
            throw PIXVError.corrupt("unexpected set of planes")
        }

        var stageBooks: [[PatternBook]] = []
        for plane in image.planes {
            var books: [PatternBook] = []
            for id in plane.codebookIDs {
                guard let codebook = image.codebook(id: id) else {
                    throw PIXVError.corrupt("plane references a missing dictionary")
                }
                books.append(codebook.book)
            }
            // Guard the unchecked pattern lookups in the reconstruction loop.
            for coding in plane.levels {
                for stage in 0..<coding.stages where books[stage].count == 0 && coding.symbolCount(stage: stage) > 0 {
                    throw PIXVError.corrupt("blocks reference an empty dictionary")
                }
            }
            stageBooks.append(books)
        }

        let planes: [Plane] = Parallel.map(image.planes.count) { index in
            let plane = reconstruct(image.planes[index], books: stageBooks[index])
            // Chroma is coded at half resolution; bring it back up with the pyramid's own filter.
            return image.planes[index].kind.isChroma ? Pyramid.upsample(plane) : plane
        }

        func plane(_ kind: PIXVPlaneKind) -> Plane? {
            image.planes.firstIndex { $0.kind == kind }.map { planes[$0] }
        }
        guard let luma = plane(.luma) else { throw PIXVError.corrupt("missing luma plane") }
        precondition(luma.width == geometry.paddedWidth && luma.height == geometry.paddedHeight)

        return ColorTransform.inverse(luma: luma, chromaBlue: plane(.chromaBlue), chromaRed: plane(.chromaRed),
                                      alpha: plane(.alpha), width: image.width, height: image.height)
    }
}
