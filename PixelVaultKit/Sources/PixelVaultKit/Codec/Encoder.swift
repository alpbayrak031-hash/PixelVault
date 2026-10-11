import Foundation

/// Everything the encoder derives from the user-facing quality setting.
struct EncoderTuning: Equatable {
    /// Mean squared error (per sample) below which a luma block needs no further patterns.
    var lumaThreshold: Float
    var chromaThreshold: Float
    /// Coarser levels use `threshold · scale^level`; errors there are spread over more pixels.
    var levelThresholdScale: Float
    var lumaStages: Int
    var chromaStages: Int
    var maxLumaPatterns: Int
    var maxChromaPatterns: Int
    /// Gain quantiser step, in half units.
    var gainStepHalves: Int
    var baseStep: Int
    var trainingIterations: Int
    /// Training residuals gathered per dictionary entry.
    var samplesPerPattern: Int
    /// Fewest uses a pattern should average before the dictionary is allowed to grow.
    var blocksPerPattern: Int
    /// A pattern is only spent on a block if it removes at least this fraction of the
    /// block's error budget — the rate–distortion test that keeps weak matches out of the file.
    var stageAcceptance: Float

    init(quality: Int) {
        let quality = max(1, min(100, quality))
        let t = Float(quality - 1) / 99

        // Log-linear from MSE 100 (≈ 28 dB) at the bottom to 2 (≈ 45 dB) at the top.
        lumaThreshold = 100 * pow(2.0 / 100, t)
        // Chroma is a quarter of the samples and its errors tint whole 2×2 pixel groups, so it
        // is held to a tighter budget than luma; measured, this is the best use of those bits.
        chromaThreshold = lumaThreshold * 0.3
        levelThresholdScale = 0.7

        switch quality {
        case ..<25: lumaStages = 2
        case ..<60: lumaStages = 3
        case ..<85: lumaStages = 4
        default: lumaStages = 5
        }
        chromaStages = max(1, lumaStages - 1)

        switch quality {
        case ..<30: maxLumaPatterns = 512
        case ..<70: maxLumaPatterns = 1024
        default: maxLumaPatterns = 2048
        }
        maxChromaPatterns = maxLumaPatterns / 2

        // A gain step of Δ adds about Δ²/12 to a block's squared error; keep that a small
        // fraction of what the block is allowed to keep.
        let step = (lumaThreshold * Float(PIXVFormat.patternLength)).squareRoot() * 0.45
        gainStepHalves = max(2, min(96, Int((step * 2).rounded())))

        baseStep = quality < 30 ? 2 : 1
        trainingIterations = 4
        samplesPerPattern = 32
        blocksPerPattern = 24
        stageAcceptance = 1
    }

    func threshold(for kind: PIXVPlaneKind, level: Int) -> Float {
        let base = kind.isChroma ? chromaThreshold : lumaThreshold
        return base * pow(levelThresholdScale, Float(level))
    }
}

/// Stage timings of one encode, in milliseconds.
public struct PIXVEncodeTimings: Sendable {
    /// RGB → planes, padding and pyramid construction.
    public var analysis: Double = 0
    /// Learning the pattern dictionaries.
    public var training: Double = 0
    /// Matching every block against the dictionaries.
    public var matching: Double = 0
    /// Entropy coding and container assembly.
    public var entropyCoding: Double = 0
    public var total: Double = 0
}

enum Encoder {
    private static let length = PIXVFormat.patternLength

    static func encode(_ image: RGBAImage, quality: Int) throws -> (image: CodedImage, timings: PIXVEncodeTimings) {
        guard image.width <= PIXVFormat.maxDimension, image.height <= PIXVFormat.maxDimension,
              image.pixelCount <= PIXVFormat.maxPixelCount
        else { throw PIXVError.invalidDimensions }

        var timings = PIXVEncodeTimings()
        var clock = Stopwatch()
        let tuning = EncoderTuning(quality: quality)
        let geometry = PIXVGeometry(width: image.width, height: image.height,
                                    lumaLevels: PIXVGeometry.recommendedLevels(width: image.width, height: image.height))

        // 1. Planes and pyramids.
        let channels = ColorTransform.forward(image)
        let isGray = channels.chromaBlue.data.allSatisfy { $0 == 128 } && channels.chromaRed.data.allSatisfy { $0 == 128 }

        var sources: [(kind: PIXVPlaneKind, plane: Plane)] = [
            (.luma, channels.luma.padded(toWidth: geometry.paddedWidth, height: geometry.paddedHeight))
        ]
        if !isGray {
            for (kind, plane) in [(PIXVPlaneKind.chromaBlue, channels.chromaBlue), (.chromaRed, channels.chromaRed)] {
                let padded = plane.padded(toWidth: geometry.paddedWidth, height: geometry.paddedHeight)
                sources.append((kind, Pyramid.downsample(padded)))
            }
        }
        if let alpha = channels.alpha {
            sources.append((.alpha, alpha.padded(toWidth: geometry.paddedWidth, height: geometry.paddedHeight)))
        }

        let pyramids: [[Plane]] = Parallel.map(sources.count) { index in
            var pyramid = [sources[index].plane]
            for _ in 0..<geometry.levels(for: sources[index].kind) {
                pyramid.append(Pyramid.downsample(pyramid[pyramid.count - 1]))
            }
            return pyramid
        }
        timings.analysis = clock.lap()

        // 2. Dictionaries: one family for luma, one shared by both chroma planes.
        func trainFamily(_ role: PIXVCodebookRole) -> [PatternBook] {
            let members = sources.indices.filter {
                role == .luma ? sources[$0].kind == .luma : sources[$0].kind.isChroma
            }
            guard let first = members.first else { return [] }
            let kind = sources[first].kind
            let levels = geometry.levels(for: kind)
            let maxPatterns = role == .luma ? tuning.maxLumaPatterns : tuning.maxChromaPatterns
            let samples = gatherSamples(pyramids: members.map { pyramids[$0] }, levels: levels,
                                        limits: (0..<levels).map { tuning.threshold(for: kind, level: $0) * Float(length) },
                                        budget: maxPatterns * tuning.samplesPerPattern)
            return trainBooks(samples, maxStages: role == .luma ? tuning.lumaStages : tuning.chromaStages,
                              maxPatterns: maxPatterns, tuning: tuning)
        }
        let lumaBooks = trainFamily(.luma)
        let chromaBooks = trainFamily(.chroma)
        timings.training = clock.lap()

        var codebooks: [CodedCodebook] = []
        for (stage, book) in lumaBooks.enumerated() {
            codebooks.append(CodedCodebook(id: codebooks.count, role: .luma, stage: stage, book: book))
        }
        let chromaIDBase = codebooks.count
        for (stage, book) in chromaBooks.enumerated() {
            codebooks.append(CodedCodebook(id: codebooks.count, role: .chroma, stage: stage, book: book))
        }

        // 3. Closed-loop coding, coarsest level first: each level is coded against the
        //    upsampled reconstruction of the one above, so errors never accumulate.
        var planes: [CodedPlane] = []
        for (index, source) in sources.enumerated() {
            let books = source.kind.isChroma ? chromaBooks : lumaBooks
            let ids = source.kind.isChroma
                ? chromaBooks.indices.map { chromaIDBase + $0 }
                : Array(lumaBooks.indices)
            planes.append(codePlane(kind: source.kind, pyramid: pyramids[index], books: books, codebookIDs: ids,
                                    tuning: tuning))
        }

        var coded = CodedImage(width: image.width, height: image.height,
                               colorModel: isGray ? .grayscale : .yCbCr420, hasAlpha: channels.alpha != nil,
                               lumaLevels: geometry.lumaLevels, quality: quality, codebooks: codebooks, planes: planes)
        compactDictionaries(&coded)
        timings.matching = clock.lap()
        return (coded, timings)
    }

    // MARK: Plane coding

    private static func codePlane(kind: PIXVPlaneKind, pyramid: [Plane], books: [PatternBook], codebookIDs: [Int],
                                  tuning: EncoderTuning) -> CodedPlane {
        let levelCount = pyramid.count - 1
        let step = tuning.baseStep
        let gainStep = Float(tuning.gainStepHalves) / 2

        var base = pyramid[levelCount]
        var reconstruction = base
        if step > 1 {
            for index in base.data.indices {
                let level = (Int(base.data[index]) + step / 2) / step
                base.data[index] = UInt8(level)
                reconstruction.data[index] = UInt8(min(255, level * step))
            }
        }

        var levels = [LevelCoding?](repeating: nil, count: levelCount)
        for level in (0..<levelCount).reversed() {
            let prediction = Pyramid.upsample(reconstruction)
            let coding = LevelCodec.encode(target: pyramid[level], prediction: prediction, books: books,
                                           gainStep: gainStep, threshold: tuning.threshold(for: kind, level: level),
                                           acceptance: tuning.stageAcceptance)
            if level > 0 {
                reconstruction = LevelCodec.reconstruct(prediction: prediction, coding: coding, books: books,
                                                        gainStep: gainStep)
            }
            levels[level] = coding
        }
        return CodedPlane(kind: kind, baseStep: step, gainStepHalves: tuning.gainStepHalves,
                          codebookIDs: codebookIDs, base: base, levels: levels.map { $0! })
    }

    /// Drops patterns no block ended up using and orders the rest by popularity.
    private static func compactDictionaries(_ image: inout CodedImage) {
        let usage = image.patternUsage()
        var remaps: [Int: [UInt16]] = [:]
        for slot in image.codebooks.indices {
            let counts = usage[image.codebooks[slot].id] ?? []
            let order = counts.indices.filter { counts[$0] > 0 }.sorted {
                counts[$0] != counts[$1] ? counts[$0] > counts[$1] : $0 < $1
            }
            var remap = [UInt16](repeating: 0, count: counts.count)
            for (newIndex, oldIndex) in order.enumerated() { remap[oldIndex] = UInt16(newIndex) }
            remaps[image.codebooks[slot].id] = remap
            image.codebooks[slot].book = image.codebooks[slot].book.reordered(order)
        }
        for planeIndex in image.planes.indices {
            let ids = image.planes[planeIndex].codebookIDs
            for level in image.planes[planeIndex].levels.indices {
                let blockCount = image.planes[planeIndex].levels[level].blockCount
                for stage in 0..<ids.count {
                    guard let remap = remaps[ids[stage]] else { continue }
                    let base = stage * blockCount
                    for block in 0..<blockCount where image.planes[planeIndex].levels[level].modes[block] > stage {
                        let old = Int(image.planes[planeIndex].levels[level].indices[base + block])
                        image.planes[planeIndex].levels[level].indices[base + block] = remap[old]
                    }
                }
            }
        }
    }

    // MARK: Training

    private struct TrainingSamples {
        /// `count × 16` residual blocks.
        var vectors: [Float] = []
        /// Squared-error budget of each sample's level.
        var limits: [Float] = []
        var count = 0
        /// Estimated number of blocks in the whole image that will need patterns.
        var population: Double = 0
    }

    /// Samples residual blocks from every level, open loop (against the upsampled *original*
    /// coarser level). That is a close stand-in for the closed-loop residuals the coder will
    /// see, and lets the dictionaries be learned before any block is coded.
    private static func gatherSamples(pyramids: [[Plane]], levels: Int, limits: [Float], budget: Int) -> TrainingSamples {
        // Work is split into a fixed number of chunks per level — not per core — so the
        // samples, and therefore the encoded bytes, are identical on every machine.
        struct Chunk {
            var pyramid: Int
            var level: Int
            var blocks: Range<Int>
            var seed: UInt64
        }
        let chunksPerLevel = 16
        var chunks: [Chunk] = []
        var totalBlocks = 0
        for (pyramidIndex, pyramid) in pyramids.enumerated() {
            for level in 0..<levels {
                let blockCount = (pyramid[level].width / 4) * (pyramid[level].height / 4)
                totalBlocks += blockCount
                for part in 0..<chunksPerLevel {
                    let range = (blockCount * part / chunksPerLevel)..<(blockCount * (part + 1) / chunksPerLevel)
                    guard !range.isEmpty else { continue }
                    chunks.append(Chunk(pyramid: pyramidIndex, level: level, blocks: range,
                                        seed: 0x5049_5856 ^ UInt64(chunks.count) &* 0x9E37_79B9))
                }
            }
        }
        guard totalBlocks > 0, budget > 0 else { return TrainingSamples() }

        // Visit a few times more blocks than needed, since many will be smooth enough to skip.
        let stride = max(1, totalBlocks / (budget * 4))

        let parts: [(vectors: [Float], limits: [Float])] = Parallel.map(chunks.count) { index in
            let chunk = chunks[index]
            let target = pyramids[chunk.pyramid][chunk.level], coarse = pyramids[chunk.pyramid][chunk.level + 1]
            let blocksWide = target.width / 4
            let limit = limits[chunk.level]
            var generator = SplitMix64(seed: chunk.seed)
            var vectors: [Float] = []
            var kept: [Float] = []
            var block = [Float](repeating: 0, count: length)
            var predicted = [Int32](repeating: 0, count: length)

            target.data.withUnsafeBufferPointer { targetBuffer in
                coarse.data.withUnsafeBufferPointer { coarseBuffer in
                    var position = chunk.blocks.lowerBound + (stride > 1 ? Int(generator.next() % UInt64(stride)) : 0)
                    while position < chunk.blocks.upperBound {
                        let originX = (position % blocksWide) * 4, originY = (position / blocksWide) * 4
                        Pyramid.upsampledBlock(coarseBuffer.baseAddress!, width: coarse.width, height: coarse.height,
                                               originX: originX, originY: originY, into: &predicted)
                        var energy: Float = 0
                        for y in 0..<4 {
                            for x in 0..<4 {
                                let value = Float(Int32(targetBuffer[(originY + y) * target.width + originX + x])
                                    - predicted[y * 4 + x])
                                block[y * 4 + x] = value
                                energy += value * value
                            }
                        }
                        if energy > limit {
                            vectors.append(contentsOf: block)
                            kept.append(limit)
                        }
                        // Jittered stride, so sampling never locks onto the image's own periodicity.
                        position += stride > 1 ? 1 + Int(generator.next() % UInt64(2 * stride - 1)) : 1
                    }
                }
            }
            return (vectors, kept)
        }

        var gathered = TrainingSamples()
        gathered.count = parts.reduce(0) { $0 + $1.limits.count }
        gathered.population = Double(gathered.count) * Double(stride)
        guard gathered.count > 0 else { return gathered }

        // Merge in chunk order, thinning evenly down to the budget.
        let keepCount = min(budget, gathered.count)
        gathered.vectors.reserveCapacity(keepCount * length)
        gathered.limits.reserveCapacity(keepCount)
        var offsets = [0]
        for part in parts { offsets.append(offsets[offsets.count - 1] + part.limits.count) }
        var part = 0
        for slot in 0..<keepCount {
            let sample = slot * gathered.count / keepCount
            while sample >= offsets[part + 1] { part += 1 }
            let local = sample - offsets[part]
            gathered.vectors.append(contentsOf: parts[part].vectors[(local * length)..<((local + 1) * length)])
            gathered.limits.append(parts[part].limits[local])
        }
        gathered.count = keepCount
        return gathered
    }

    /// Learns one dictionary per stage. Each later stage is trained on what the earlier
    /// ones leave behind — a residual ("multi-stage") codebook hierarchy.
    private static func trainBooks(_ samples: TrainingSamples, maxStages: Int, maxPatterns: Int,
                                   tuning: EncoderTuning) -> [PatternBook] {
        var vectors = samples.vectors
        var limits = samples.limits
        var count = samples.count
        var population = samples.population
        let gainStep = Float(tuning.gainStepHalves) / 2
        let maxGain = Float(PIXVFormat.maxGain)
        var books: [PatternBook] = []

        for stage in 0..<maxStages {
            // Large images earn one pattern per `blocksPerPattern` blocks that need one. Small
            // images cannot amortise a dictionary that way, so they get a floor of a pattern per
            // four blocks (up to 64) — otherwise they would be left with the blurry base alone.
            let blocks = Int(population)
            let patternCount = min(maxPatterns, max(blocks / tuning.blocksPerPattern, min(blocks / 4, 64)), count / 2)
            guard patternCount >= 2 else { break }
            let rows = CodebookTrainer.train(samples: vectors, count: count, patternCount: patternCount,
                                             iterations: tuning.trainingIterations)
            let book = PatternBook(quantizing: rows)
            books.append(book)
            if stage == maxStages - 1 { break }

            // Peel this stage off the training set to expose the next stage's residuals.
            var winners = [UInt16](repeating: 0, count: count)
            var dots = [Float](repeating: 0, count: count)
            vectors.withUnsafeBufferPointer {
                PatternSearch.search(vectors: $0.baseAddress!, count: count, book: book, indices: &winners, gains: &dots)
            }
            var kept = 0
            for sample in 0..<count {
                let quantized = max(-maxGain, min(maxGain, (dots[sample] / gainStep).rounded()))
                let applied = quantized * gainStep
                guard quantized != 0, applied * (2 * dots[sample] - applied) >= tuning.stageAcceptance * limits[sample]
                else { continue }
                var energy: Float = 0
                let pattern = Int(winners[sample]) * length
                for element in 0..<length {
                    let value = vectors[sample * length + element] - applied * book.patterns[pattern + element]
                    vectors[kept * length + element] = value
                    energy += value * value
                }
                if energy > limits[sample] {
                    limits[kept] = limits[sample]
                    kept += 1
                }
            }
            population *= Double(kept) / Double(max(1, count))
            count = kept
        }
        return books
    }
}

/// Small, fast, deterministic generator, so the same image always encodes to the same bytes.
struct SplitMix64 {
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
