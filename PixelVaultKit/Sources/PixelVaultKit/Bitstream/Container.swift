import Foundation

/// Serialises a `CodedImage` to `.pixv` bytes and parses it back.
///
/// Every entropy-coded stream is length-prefixed and self-contained, so both directions
/// fan the streams out across cores. See `Docs/PIXV-Format.md` for the byte layout.
enum Container {
    typealias Sizes = [PIXVSizeCategory: Int]

    private static let gainScaleBits = RANS.smallScaleBits
    private static let patternByteScaleBits = RANS.smallScaleBits
    private static let indexScaleBits = RANS.largeScaleBits

    // MARK: - Writing

    private enum Stream {
        case base(plane: Int)
        case modes(plane: Int, level: Int)
        case indices(plane: Int, level: Int, stage: Int)
        case gains(plane: Int, level: Int, stage: Int)
        case patterns(codebook: Int)
    }

    static func write(_ image: CodedImage) -> (bytes: [UInt8], sizes: Sizes) {
        // Flatten per-block pattern data into the symbol runs that get entropy coded.
        var levelSlots: [(plane: Int, level: Int)] = []
        for (planeIndex, plane) in image.planes.enumerated() {
            for level in plane.levels.indices { levelSlots.append((planeIndex, level)) }
        }
        let flattened: [[(indices: [UInt16], gains: [UInt16])]] = Parallel.map(levelSlots.count) { slot in
            let plane = image.planes[levelSlots[slot].plane]
            let coding = plane.levels[levelSlots[slot].level]
            return (0..<plane.stages).map { StageSymbols.flatten(coding, stage: $0) }
        }
        var flatLookup: [[Int]] = image.planes.map { [Int](repeating: 0, count: $0.levels.count) }
        for (slot, entry) in levelSlots.enumerated() { flatLookup[entry.plane][entry.level] = slot }

        // One usage table per dictionary, shared by every stream that indexes it.
        var usage = [[Int]](repeating: [], count: image.codebooks.count)
        var codebookSlot: [Int: Int] = [:]
        for (slot, codebook) in image.codebooks.enumerated() {
            usage[slot] = [Int](repeating: 0, count: codebook.book.count)
            codebookSlot[codebook.id] = slot
        }
        for (planeIndex, plane) in image.planes.enumerated() {
            for level in plane.levels.indices {
                for stage in 0..<plane.stages {
                    let slot = codebookSlot[plane.codebookIDs[stage]]!
                    for index in flattened[flatLookup[planeIndex][level]][stage].indices {
                        usage[slot][Int(index)] += 1
                    }
                }
            }
        }
        let indexTables = usage.map { FrequencyTable(counts: $0, scaleBits: indexScaleBits) }

        // Entropy-code every stream concurrently.
        var streams: [Stream] = []
        var streamSlot: [String: Int] = [:]
        func add(_ stream: Stream, key: String) {
            streamSlot[key] = streams.count
            streams.append(stream)
        }
        for (planeIndex, plane) in image.planes.enumerated() {
            add(.base(plane: planeIndex), key: "b\(planeIndex)")
            for level in plane.levels.indices {
                add(.modes(plane: planeIndex, level: level), key: "m\(planeIndex).\(level)")
                for stage in 0..<plane.stages
                where !flattened[flatLookup[planeIndex][level]][stage].indices.isEmpty {
                    add(.indices(plane: planeIndex, level: level, stage: stage), key: "i\(planeIndex).\(level).\(stage)")
                    add(.gains(plane: planeIndex, level: level, stage: stage), key: "g\(planeIndex).\(level).\(stage)")
                }
            }
        }
        for slot in image.codebooks.indices where image.codebooks[slot].book.count > 0 {
            add(.patterns(codebook: slot), key: "p\(slot)")
        }

        let payloads: [[UInt8]] = Parallel.map(streams.count) { job in
            switch streams[job] {
            case .base(let planeIndex):
                let plane = image.planes[planeIndex]
                return BaseLayerCodec.encode(levels: plane.base, step: plane.baseStep)

            case .modes(let planeIndex, let level):
                let plane = image.planes[planeIndex]
                let parent = level + 1 < plane.levels.count
                    ? ModeCodec.Parent(modes: plane.levels[level + 1].modes, blocksWide: plane.levels[level + 1].blocksWide)
                    : nil
                return ModeCodec.encode(plane.levels[level], parent: parent, alphabetSize: plane.stages + 1)

            case .indices(let planeIndex, let level, let stage):
                let slot = codebookSlot[image.planes[planeIndex].codebookIDs[stage]]!
                return SymbolStream.encode(flattened[flatLookup[planeIndex][level]][stage].indices,
                                           table: indexTables[slot])

            case .gains(let planeIndex, let level, let stage):
                return encodeWithTable(flattened[flatLookup[planeIndex][level]][stage].gains,
                                       alphabetSize: PIXVFormat.gainAlphabet, scaleBits: gainScaleBits)

            case .patterns(let slot):
                let symbols = image.codebooks[slot].book.stored.map { UInt16(Int($0) + 128) }
                return encodeWithTable(symbols, alphabetSize: 256, scaleBits: patternByteScaleBits)
            }
        }

        // Assemble.
        var sizes: Sizes = [:]
        var body = ByteWriter(reservingCapacity: payloads.reduce(1024) { $0 + $1.count + 8 })

        func writeStream(_ payload: [UInt8], _ category: PIXVSizeCategory, into writer: inout ByteWriter) {
            let before = writer.count
            writer.varint(payload.count)
            sizes[.container, default: 0] += writer.count - before
            writer.append(payload)
            sizes[category, default: 0] += payload.count
        }

        func writeSection(_ tag: [UInt8], _ payload: ByteWriter) {
            body.append(tag)
            body.u32(UInt32(payload.count))
            body.append(payload.bytes)
            sizes[.container, default: 0] += 8
        }

        var codebookSection = ByteWriter()
        codebookSection.u8(UInt8(image.codebooks.count))
        sizes[.container, default: 0] += 1
        for (slot, codebook) in image.codebooks.enumerated() {
            let before = codebookSection.count
            codebookSection.u8(UInt8(codebook.id))
            codebookSection.u8(codebook.role.rawValue)
            codebookSection.u8(UInt8(codebook.stage))
            codebookSection.varint(codebook.book.count)
            if codebook.book.count > 0 {
                indexTables[slot].write(to: &codebookSection)
            }
            sizes[.dictionary, default: 0] += codebookSection.count - before
            if codebook.book.count > 0 {
                writeStream(payloads[streamSlot["p\(slot)"]!], .dictionary, into: &codebookSection)
            }
        }
        writeSection(PIXVFormat.SectionTag.codebooks, codebookSection)

        for (planeIndex, plane) in image.planes.enumerated() {
            var section = ByteWriter()
            section.u8(plane.kind.rawValue)
            section.u8(UInt8(plane.levels.count))
            section.u8(UInt8(plane.stages))
            section.u8(UInt8(plane.baseStep))
            section.u8(UInt8(plane.gainStepHalves))
            for id in plane.codebookIDs { section.u8(UInt8(id)) }
            sizes[.container, default: 0] += section.count

            writeStream(payloads[streamSlot["b\(planeIndex)"]!], .baseLayer, into: &section)
            for level in plane.levels.indices.reversed() {
                writeStream(payloads[streamSlot["m\(planeIndex).\(level)"]!], .blockModes, into: &section)
                for stage in 0..<plane.stages {
                    let symbolCount = flattened[flatLookup[planeIndex][level]][stage].indices.count
                    let before = section.count
                    section.varint(symbolCount)
                    sizes[.container, default: 0] += section.count - before
                    guard symbolCount > 0 else { continue }
                    writeStream(payloads[streamSlot["i\(planeIndex).\(level).\(stage)"]!], .patternIndices, into: &section)
                    writeStream(payloads[streamSlot["g\(planeIndex).\(level).\(stage)"]!], .gains, into: &section)
                }
            }
            writeSection(PIXVFormat.SectionTag.plane, section)
        }

        let checksum = body.bytes.withUnsafeBufferPointer { CRC32.checksum($0) }
        let header = PIXVHeader(flags: image.hasAlpha ? PIXVFormat.Flags.hasAlpha : 0,
                                width: image.width, height: image.height, colorModel: image.colorModel,
                                lumaLevels: image.lumaLevels, quality: image.quality, checksum: checksum)
        var file = ByteWriter(reservingCapacity: PIXVFormat.headerSize + body.count)
        header.write(to: &file)
        file.append(body.bytes)
        sizes[.container, default: 0] += PIXVFormat.headerSize
        return (file.bytes, sizes)
    }

    /// A self-describing order-0 stream: its frequency table, then the rANS bytes.
    private static func encodeWithTable(_ symbols: [UInt16], alphabetSize: Int, scaleBits: Int) -> [UInt8] {
        var counts = [Int](repeating: 0, count: alphabetSize)
        for symbol in symbols { counts[Int(symbol)] += 1 }
        let table = FrequencyTable(counts: counts, scaleBits: scaleBits)
        var writer = ByteWriter()
        table.write(to: &writer)
        writer.append(SymbolStream.encode(symbols, table: table))
        return writer.bytes
    }

    private static func decodeWithTable(_ bytes: [UInt8], range: Range<Int>, count: Int,
                                        alphabetSize: Int, scaleBits: Int) throws -> [UInt16] {
        var reader = ByteReader(bytes, range: range)
        let table = try FrequencyTable(reading: &reader, scaleBits: scaleBits, alphabetSize: alphabetSize)
        guard !table.isEmpty else { throw PIXVError.corrupt("stream has no probability table") }
        let decodeTable = SymbolDecodeTable(table)
        return try bytes.withUnsafeBufferPointer {
            try SymbolStream.decode(UnsafeBufferPointer(rebasing: $0[reader.offset..<range.upperBound]),
                                    count: count, table: decodeTable)
        }
    }

    // MARK: - Reading

    /// Reads just the fixed header, without validating the payload.
    static func readHeader(_ bytes: [UInt8]) throws -> PIXVHeader {
        var reader = ByteReader(bytes)
        return try PIXVHeader(reading: &reader)
    }

    private struct StageLayout {
        var symbolCount = 0
        var indices: Range<Int> = 0..<0
        var gains: Range<Int> = 0..<0
    }

    private struct LevelLayout {
        var modes: Range<Int> = 0..<0
        var stages: [StageLayout] = []
    }

    private struct PlaneLayout {
        var kind: PIXVPlaneKind
        var baseStep: Int
        var gainStepHalves: Int
        var codebookIDs: [Int]
        var base: Range<Int>
        /// Index 0 is full plane resolution.
        var levels: [LevelLayout]
    }

    private struct CodebookLayout {
        var id: Int
        var role: PIXVCodebookRole
        var stage: Int
        var patternCount: Int
        var indexTable: FrequencyTable?
        var patterns: Range<Int>
    }

    /// Parses a file. With `reduction > 0` the finest pyramid levels are left undecoded, which
    /// yields an image `2^reduction` times smaller for a fraction of the work — the pyramid
    /// makes every `.pixv` its own thumbnail.
    static func read(_ bytes: [UInt8], reduction: Int = 0) throws -> (image: CodedImage, sizes: Sizes) {
        var reader = ByteReader(bytes)
        let header = try PIXVHeader(reading: &reader)
        guard CRC32.checksum(bytes, range: reader.offset..<bytes.count) == header.checksum else {
            throw PIXVError.checksumMismatch
        }
        let geometry = PIXVGeometry(width: header.width, height: header.height, lumaLevels: header.lumaLevels)
        precondition((0...header.lumaLevels).contains(reduction), "reduction exceeds the pyramid depth")

        var sizes: Sizes = [.container: PIXVFormat.headerSize]
        var codebookLayouts: [CodebookLayout] = []
        var planeLayouts: [PlaneLayout] = []
        var sawCodebooks = false

        func takeStream(_ reader: inout ByteReader, _ category: PIXVSizeCategory) throws -> Range<Int> {
            let before = reader.offset
            let length = try reader.varint()
            sizes[.container, default: 0] += reader.offset - before
            sizes[category, default: 0] += length
            return try reader.take(length)
        }

        // Pass 1: walk the structure and record where every stream lives.
        while !reader.isAtEnd {
            let tag = Array(bytes[try reader.take(4)])
            let length = Int(try reader.u32())
            var section = ByteReader(bytes, range: try reader.take(length))
            sizes[.container, default: 0] += 8

            if tag == PIXVFormat.SectionTag.codebooks {
                guard !sawCodebooks else { throw PIXVError.corrupt("duplicate dictionary section") }
                sawCodebooks = true
                let count = Int(try section.u8())
                sizes[.container, default: 0] += 1
                guard count <= PIXVFormat.maxCodebooks else { throw PIXVError.corrupt("too many dictionaries") }
                for _ in 0..<count {
                    let before = section.offset
                    let id = Int(try section.u8())
                    guard let role = PIXVCodebookRole(rawValue: try section.u8()) else {
                        throw PIXVError.corrupt("unknown dictionary role")
                    }
                    let stage = Int(try section.u8())
                    let patternCount = try section.varint()
                    guard patternCount <= PIXVFormat.maxPatterns else { throw PIXVError.corrupt("dictionary too large") }
                    guard !codebookLayouts.contains(where: { $0.id == id }) else {
                        throw PIXVError.corrupt("duplicate dictionary id")
                    }
                    var layout = CodebookLayout(id: id, role: role, stage: stage, patternCount: patternCount,
                                                indexTable: nil, patterns: 0..<0)
                    if patternCount > 0 {
                        layout.indexTable = try FrequencyTable(reading: &section, scaleBits: indexScaleBits,
                                                               alphabetSize: patternCount)
                    }
                    sizes[.dictionary, default: 0] += section.offset - before
                    if patternCount > 0 {
                        layout.patterns = try takeStream(&section, .dictionary)
                    }
                    codebookLayouts.append(layout)
                }
            } else if tag == PIXVFormat.SectionTag.plane {
                let before = section.offset
                guard let kind = PIXVPlaneKind(rawValue: try section.u8()) else {
                    throw PIXVError.corrupt("unknown plane kind")
                }
                let levelCount = Int(try section.u8())
                let stageCount = Int(try section.u8())
                let baseStep = Int(try section.u8())
                let gainStepHalves = Int(try section.u8())
                guard levelCount == geometry.levels(for: kind) else { throw PIXVError.corrupt("plane depth mismatch") }
                guard stageCount <= PIXVFormat.maxStages else { throw PIXVError.corrupt("too many stages") }
                guard baseStep >= 1, gainStepHalves >= 1 else { throw PIXVError.corrupt("invalid quantiser step") }
                var codebookIDs: [Int] = []
                for _ in 0..<stageCount { codebookIDs.append(Int(try section.u8())) }
                sizes[.container, default: 0] += section.offset - before

                let base = try takeStream(&section, .baseLayer)
                var levels = [LevelLayout](repeating: LevelLayout(), count: levelCount)
                for level in (0..<levelCount).reversed() {
                    levels[level].modes = try takeStream(&section, .blockModes)
                    for _ in 0..<stageCount {
                        var stage = StageLayout()
                        let countStart = section.offset
                        stage.symbolCount = try section.varint()
                        sizes[.container, default: 0] += section.offset - countStart
                        if stage.symbolCount > 0 {
                            stage.indices = try takeStream(&section, .patternIndices)
                            stage.gains = try takeStream(&section, .gains)
                        }
                        levels[level].stages.append(stage)
                    }
                }
                planeLayouts.append(PlaneLayout(kind: kind, baseStep: baseStep, gainStepHalves: gainStepHalves,
                                                codebookIDs: codebookIDs, base: base, levels: levels))
            }
            // Unknown sections are skipped so later minor versions can add optional ones.
        }

        var image = CodedImage(width: header.width, height: header.height, colorModel: header.colorModel,
                               hasAlpha: header.hasAlpha, lumaLevels: header.lumaLevels, quality: header.quality,
                               codebooks: [], planes: [])
        guard planeLayouts.map(\.kind) == image.expectedPlaneKinds else {
            throw PIXVError.corrupt("unexpected set of planes")
        }

        // Dictionaries first: index streams need their tables.
        let codebooks: [Result<CodedCodebook, Error>] = Parallel.map(codebookLayouts.count) { slot in
            let layout = codebookLayouts[slot]
            return Result {
                var stored: [Int8] = []
                if layout.patternCount > 0 {
                    let symbols = try decodeWithTable(bytes, range: layout.patterns,
                                                      count: layout.patternCount * PIXVFormat.patternLength,
                                                      alphabetSize: 256, scaleBits: patternByteScaleBits)
                    stored = symbols.map { Int8(Int($0) - 128) }
                }
                return CodedCodebook(id: layout.id, role: layout.role, stage: layout.stage,
                                     book: PatternBook(stored: stored))
            }
        }
        image.codebooks = try codebooks.map { try $0.get() }

        var indexDecodeTables: [Int: SymbolDecodeTable] = [:]
        for layout in codebookLayouts {
            if let table = layout.indexTable, !table.isEmpty {
                indexDecodeTables[layout.id] = SymbolDecodeTable(table)
            }
        }
        for plane in planeLayouts {
            for id in plane.codebookIDs where !codebookLayouts.contains(where: { $0.id == id }) {
                throw PIXVError.corrupt("plane references a missing dictionary")
            }
        }

        // Pass 2: decode every stream. A plane's base layer and block maps form one sequential
        // job (each block map is modelled on the one above it); index and gain runs are independent.
        enum Job {
            case structure(plane: Int)
            case indices(plane: Int, level: Int, stage: Int)
            case gains(plane: Int, level: Int, stage: Int)
        }
        enum Output {
            case structure(base: Plane, modes: [[UInt8]])
            case symbols([UInt16])
        }

        // First level each plane decodes; everything finer is skipped at reduced size.
        let firstLevel = planeLayouts.map { geometry.skippedLevels(for: $0.kind, reduction: reduction) }

        var jobs: [Job] = []
        for (planeIndex, plane) in planeLayouts.enumerated() {
            jobs.append(.structure(plane: planeIndex))
            for (level, levelLayout) in plane.levels.enumerated() where level >= firstLevel[planeIndex] {
                for (stage, stageLayout) in levelLayout.stages.enumerated() where stageLayout.symbolCount > 0 {
                    jobs.append(.indices(plane: planeIndex, level: level, stage: stage))
                    jobs.append(.gains(plane: planeIndex, level: level, stage: stage))
                }
            }
        }

        let outputs: [Result<Output, Error>] = Parallel.map(jobs.count) { job in
            Result {
                switch jobs[job] {
                case .structure(let planeIndex):
                    let layout = planeLayouts[planeIndex]
                    let size = geometry.planeSize(for: layout.kind)
                    let levelCount = layout.levels.count
                    let base = try BaseLayerCodec.decode(bytes, range: layout.base, width: size.width >> levelCount,
                                                         height: size.height >> levelCount, step: layout.baseStep)
                    var modes = [[UInt8]](repeating: [], count: levelCount)
                    for level in (firstLevel[planeIndex]..<levelCount).reversed() {
                        let blocksWide = (size.width >> level) / PIXVFormat.blockSize
                        let blocksHigh = (size.height >> level) / PIXVFormat.blockSize
                        let parent = level + 1 < levelCount
                            ? ModeCodec.Parent(modes: modes[level + 1], blocksWide: blocksWide / 2)
                            : nil
                        modes[level] = try ModeCodec.decode(bytes, range: layout.levels[level].modes,
                                                            blocksWide: blocksWide, blocksHigh: blocksHigh,
                                                            parent: parent, alphabetSize: layout.codebookIDs.count + 1)
                    }
                    return .structure(base: base, modes: modes)

                case .indices(let planeIndex, let level, let stage):
                    let layout = planeLayouts[planeIndex]
                    let stageLayout = layout.levels[level].stages[stage]
                    guard let table = indexDecodeTables[layout.codebookIDs[stage]] else {
                        throw PIXVError.corrupt("blocks reference an empty dictionary")
                    }
                    return .symbols(try bytes.withUnsafeBufferPointer {
                        try SymbolStream.decode(UnsafeBufferPointer(rebasing: $0[stageLayout.indices]),
                                                count: stageLayout.symbolCount, table: table)
                    })

                case .gains(let planeIndex, let level, let stage):
                    let stageLayout = planeLayouts[planeIndex].levels[level].stages[stage]
                    return .symbols(try decodeWithTable(bytes, range: stageLayout.gains, count: stageLayout.symbolCount,
                                                        alphabetSize: PIXVFormat.gainAlphabet, scaleBits: gainScaleBits))
                }
            }
        }

        // Pass 3: put the symbol runs back on their blocks.
        var symbolRuns: [String: [UInt16]] = [:]
        var structures: [Int: (base: Plane, modes: [[UInt8]])] = [:]
        for (job, output) in zip(jobs, outputs) {
            switch (job, try output.get()) {
            case (.structure(let planeIndex), .structure(let base, let modes)):
                structures[planeIndex] = (base, modes)
            case (.indices(let planeIndex, let level, let stage), .symbols(let symbols)):
                symbolRuns["i\(planeIndex).\(level).\(stage)"] = symbols
            case (.gains(let planeIndex, let level, let stage), .symbols(let symbols)):
                symbolRuns["g\(planeIndex).\(level).\(stage)"] = symbols
            default:
                throw PIXVError.corrupt("internal stream mismatch")
            }
        }

        for (planeIndex, layout) in planeLayouts.enumerated() {
            let structure = structures[planeIndex]!
            let size = geometry.planeSize(for: layout.kind)
            let stageCount = layout.codebookIDs.count
            var levels: [LevelCoding] = []
            for level in firstLevel[planeIndex]..<layout.levels.count {
                var coding = LevelCoding(blocksWide: (size.width >> level) / PIXVFormat.blockSize,
                                         blocksHigh: (size.height >> level) / PIXVFormat.blockSize,
                                         stages: stageCount)
                coding.modes = structure.modes[level]
                for stage in 0..<stageCount {
                    let expected = layout.levels[level].stages[stage].symbolCount
                    guard coding.symbolCount(stage: stage) == expected else {
                        throw PIXVError.corrupt("block map disagrees with pattern count")
                    }
                    guard expected > 0 else { continue }
                    StageSymbols.scatter(indices: symbolRuns["i\(planeIndex).\(level).\(stage)"]!,
                                         gains: symbolRuns["g\(planeIndex).\(level).\(stage)"]!,
                                         into: &coding, stage: stage)
                }
                levels.append(coding)
            }
            image.planes.append(CodedPlane(kind: layout.kind, baseStep: layout.baseStep,
                                           gainStepHalves: layout.gainStepHalves, codebookIDs: layout.codebookIDs,
                                           base: structure.base, levels: levels))
        }
        image.reduction = reduction
        return (image, sizes)
    }
}
