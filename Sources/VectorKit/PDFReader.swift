import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

/// PDF → VectorDocument on `CGPDFScanner` (formats §3.1): paths, clips, text (in its embedded TrueType/OpenType program
/// when the program's character map agrees with the PDF's glyphs, as outlines when it doesn't, other fonts as text in a
/// stand-in font), images with masks, axial/radial shadings and tiling patterns, form
/// XObjects. Soft masks, blend modes and mesh shadings are flagged in the loss notes, never silently dropped.
public enum PDFReader {
    public static func read(_ url: URL, password: String? = nil) throws -> VectorReadResult {
        guard let document = CGPDFDocument(url as CFURL) else { throw ConversionError.damaged("pdf") }
        return try read(document, password: password)
    }

    public static func read(data: Data, password: String? = nil) throws -> VectorReadResult {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { throw ConversionError.damaged("pdf") }
        return try read(document, password: password)
    }

    static func read(_ document: CGPDFDocument, password: String?) throws -> VectorReadResult {
        if document.isEncrypted, !document.isUnlocked {
            if !(password.map { document.unlockWithPassword($0) } ?? false), !document.unlockWithPassword("") { throw ConversionError.passwordRequired("pdf") }
        }
        guard document.numberOfPages > 0 else { throw ConversionError.damaged("pdf") }
        var pages: [VectorPage] = []
        var notes: Set<LossNote> = []
        var warnings: [String] = []
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index) else { continue }
            let interpreter = PDFInterpreter(page: page)
            pages.append(interpreter.run())
            notes.formUnion(interpreter.lossNotes)
            warnings.append(contentsOf: interpreter.warnings.filter { !warnings.contains($0) })
        }
        var title: String?
        if let info = document.info, let raw = PDFObj.string(info, "Title") { title = decodeTextString(raw) }
        return VectorReadResult(document: VectorDocument(pages: pages, title: title?.isEmpty == false ? title : nil),
                                lossNotes: notes.sorted { ($0.kind.rawValue, $0.detail) < ($1.kind.rawValue, $1.detail) }, warnings: warnings)
    }

    static func decodeTextString(_ data: Data) -> String {
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}

/// Graphics state.
struct PDFGState {
    var ctm: VectorTransform
    var fillSpace = PDFColourSpace.deviceGray, strokeSpace = PDFColourSpace.deviceGray
    var fillComps: [Double] = [0], strokeComps: [Double] = [0]
    var fillPattern: String?, strokePattern: String?
    var lineWidth = 1.0
    var cap = LineCap.butt, join = LineJoin.miter
    var miter = 10.0
    var dash: [Double] = [], dashPhase = 0.0
    var fillAlpha = 1.0, strokeAlpha = 1.0
    var font: PDFFont?
    var fontSize = 1.0
    var charSpace = 0.0, wordSpace = 0.0, hScale = 1.0, leading = 0.0, rise = 0.0
    var renderMode = 0
}

func pointerKey<T>(_ p: T) -> UInt { unsafeBitCast(p, to: UInt.self) }

final class PDFInterpreter {
    struct Level { var clip: [PathSegment]?; var opacity: Double; var nodes: [VectorNode] }

    let page: CGPDFPage
    var lossNotes: Set<LossNote> = []
    var warnings: [String] = []
    var gs: PDFGState
    var saved: [(PDFGState, Int)] = []
    var levels: [Level] = [Level(clip: nil, opacity: 1, nodes: [])]
    var path: [PathSegment] = []
    var current = VectorPoint(0, 0), subpathStart = VectorPoint(0, 0)
    var pendingClip = false
    var streams: [CGPDFContentStreamRef] = []
    var baseCTMs: [VectorTransform] = []
    var fonts: [UInt: PDFFont] = [:]
    var tm = VectorTransform.identity, tlm = VectorTransform.identity
    var budget = 2_000_000
    var formDepth = 0
    var activeForms: Set<UInt> = []
    var imageCache: [UInt: ImageAsset] = [:]
    let pageBase: VectorTransform
    let size: VectorSize

    init(page: CGPDFPage) {
        self.page = page
        let crop = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let w = rotated ? crop.height : crop.width, h = rotated ? crop.width : crop.height
        size = VectorSize(width: max(1, Double(w)), height: max(1, Double(h)))
        pageBase = VectorTransform(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: size.width, height: size.height), rotate: 0, preserveAspectRatio: true))
        gs = PDFGState(ctm: pageBase)
    }

    func note(_ kind: LossNote.Kind, _ detail: String) {
        lossNotes.insert(LossNote(kind, detail: detail))
        if !warnings.contains(detail) { warnings.append(detail) }
    }

    func run() -> VectorPage {
        let cs = CGPDFContentStreamCreateWithPage(page)
        streams = [cs]
        baseCTMs = [pageBase]
        scan(cs)
        while levels.count > 1 { closeLevel() }
        return VectorPage(size: size, background: nil, nodes: levels[0].nodes)
    }

    func scan(_ cs: CGPDFContentStreamRef) {
        let scanner = CGPDFScannerCreate(cs, PDFInterpreter.operatorTable, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    // MARK: Levels and output

    func emit(_ node: VectorNode) {
        budget -= 1
        if budget > 0 { levels[levels.count - 1].nodes.append(node) }
    }

    /// Opens a clip or opacity level, unless levels are already nested `maxGroupNesting` deep (a clip without a matching
    /// `Q`, repeated); then the level is left out, with a note. Whether it was opened.
    @discardableResult
    func openLevel(_ level: Level) -> Bool {
        guard levels.count < maxGroupNesting else { note(.otherLoss, "Clips nested too deep were left out"); return false }
        levels.append(level)
        return true
    }

    func closeLevel() {
        guard levels.count > 1 else { return }
        let level = levels.removeLast()
        if level.nodes.isEmpty { return }
        levels[levels.count - 1].nodes.append(.group(level.nodes, transform: .identity, clip: level.clip, opacity: level.opacity))
    }

    func resource(_ category: String, _ name: String) -> CGPDFObjectRef? {
        guard let cs = streams.last else { return nil }
        return CGPDFContentStreamGetResource(cs, category, name)
    }

    func colourSpace(named name: String) -> PDFColourSpace? {
        PDFColourSpace.named(name) { [unowned self] n in self.resource("ColorSpace", n) }
    }

    // MARK: Operator table

    nonisolated(unsafe) static let operatorTable: CGPDFOperatorTableRef = {
        let t = CGPDFOperatorTableCreate()!
        func reg(_ name: String, _ f: @escaping @convention(c) (CGPDFScannerRef, UnsafeMutableRawPointer?) -> Void) { CGPDFOperatorTableSetCallback(t, name, f) }
        func me(_ info: UnsafeMutableRawPointer?) -> PDFInterpreter { Unmanaged<PDFInterpreter>.fromOpaque(info!).takeUnretainedValue() }
        reg("q") { _, i in me(i).opSave() }
        reg("Q") { _, i in me(i).opRestore() }
        reg("cm") { s, i in me(i).opConcat(s) }
        reg("w") { s, i in if let v = popNumber(s) { me(i).gs.lineWidth = v } }
        reg("J") { s, i in if let v = popNumber(s) { me(i).gs.cap = v == 1 ? .round : v == 2 ? .square : .butt } }
        reg("j") { s, i in if let v = popNumber(s) { me(i).gs.join = v == 1 ? .round : v == 2 ? .bevel : .miter } }
        reg("M") { s, i in if let v = popNumber(s) { me(i).gs.miter = v } }
        reg("d") { s, i in me(i).opDash(s) }
        reg("gs") { s, i in me(i).opExtGState(s) }
        reg("m") { s, i in me(i).opMove(s) }
        reg("l") { s, i in me(i).opLine(s) }
        reg("c") { s, i in me(i).opCurve(s, kind: 0) }
        reg("v") { s, i in me(i).opCurve(s, kind: 1) }
        reg("y") { s, i in me(i).opCurve(s, kind: 2) }
        reg("h") { _, i in me(i).opClose() }
        reg("re") { s, i in me(i).opRect(s) }
        reg("S") { _, i in me(i).paint(fill: false, stroke: true, rule: .nonZero, close: false) }
        reg("s") { _, i in me(i).paint(fill: false, stroke: true, rule: .nonZero, close: true) }
        reg("f") { _, i in me(i).paint(fill: true, stroke: false, rule: .nonZero, close: false) }
        reg("F") { _, i in me(i).paint(fill: true, stroke: false, rule: .nonZero, close: false) }
        reg("f*") { _, i in me(i).paint(fill: true, stroke: false, rule: .evenOdd, close: false) }
        reg("B") { _, i in me(i).paint(fill: true, stroke: true, rule: .nonZero, close: false) }
        reg("B*") { _, i in me(i).paint(fill: true, stroke: true, rule: .evenOdd, close: false) }
        reg("b") { _, i in me(i).paint(fill: true, stroke: true, rule: .nonZero, close: true) }
        reg("b*") { _, i in me(i).paint(fill: true, stroke: true, rule: .evenOdd, close: true) }
        reg("n") { _, i in me(i).paint(fill: false, stroke: false, rule: .nonZero, close: false) }
        reg("W") { _, i in me(i).pendingClip = true }
        reg("W*") { _, i in me(i).pendingClip = true }
        reg("g") { s, i in me(i).setDevice(s, stroke: false, space: .deviceGray, count: 1) }
        reg("G") { s, i in me(i).setDevice(s, stroke: true, space: .deviceGray, count: 1) }
        reg("rg") { s, i in me(i).setDevice(s, stroke: false, space: .deviceRGB, count: 3) }
        reg("RG") { s, i in me(i).setDevice(s, stroke: true, space: .deviceRGB, count: 3) }
        reg("k") { s, i in me(i).setDevice(s, stroke: false, space: .deviceCMYK, count: 4) }
        reg("K") { s, i in me(i).setDevice(s, stroke: true, space: .deviceCMYK, count: 4) }
        reg("cs") { s, i in me(i).opSetSpace(s, stroke: false) }
        reg("CS") { s, i in me(i).opSetSpace(s, stroke: true) }
        reg("sc") { s, i in me(i).opSetColour(s, stroke: false) }
        reg("scn") { s, i in me(i).opSetColour(s, stroke: false) }
        reg("SC") { s, i in me(i).opSetColour(s, stroke: true) }
        reg("SCN") { s, i in me(i).opSetColour(s, stroke: true) }
        reg("sh") { s, i in me(i).opShading(s) }
        reg("Do") { s, i in me(i).opDo(s) }
        reg("BT") { _, i in me(i).tm = .identity; me(i).tlm = .identity }
        reg("ET") { _, _ in }
        reg("Tc") { s, i in if let v = popNumber(s) { me(i).gs.charSpace = v } }
        reg("Tw") { s, i in if let v = popNumber(s) { me(i).gs.wordSpace = v } }
        reg("Tz") { s, i in if let v = popNumber(s) { me(i).gs.hScale = v / 100 } }
        reg("TL") { s, i in if let v = popNumber(s) { me(i).gs.leading = v } }
        reg("Tr") { s, i in if let v = popNumber(s) { me(i).gs.renderMode = v.checkedInt ?? 0 } }
        reg("Ts") { s, i in if let v = popNumber(s) { me(i).gs.rise = v } }
        reg("Tf") { s, i in me(i).opFont(s) }
        reg("Td") { s, i in me(i).opTd(s, setLeading: false) }
        reg("TD") { s, i in me(i).opTd(s, setLeading: true) }
        reg("Tm") { s, i in me(i).opTm(s) }
        reg("T*") { _, i in me(i).nextLine() }
        reg("Tj") { s, i in me(i).opTj(s) }
        reg("TJ") { s, i in me(i).opTJ(s) }
        reg("'") { s, i in me(i).nextLine(); me(i).opTj(s) }
        reg("\"") { s, i in me(i).opQuote(s) }
        return t
    }()

    // MARK: Graphics state operators

    func opSave() { saved.append((gs, levels.count)); if saved.count > 512 { saved.removeFirst() } }

    func opRestore() {
        guard let (state, depth) = saved.popLast() else { return }
        while levels.count > depth { closeLevel() }
        gs = state
    }

    func opConcat(_ s: CGPDFScannerRef) {
        guard let v = popNumbers(s, 6) else { return }
        gs.ctm = VectorTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).then(gs.ctm)
    }

    func opDash(_ s: CGPDFScannerRef) {
        let phase = popNumber(s) ?? 0
        var arr: CGPDFArrayRef?
        guard CGPDFScannerPopArray(s, &arr), let arr else { return }
        let d = PDFObj.numbers(arr)
        gs.dash = d.allSatisfy({ $0 == 0 }) ? [] : (d.count % 2 == 1 ? d + d : d)
        gs.dashPhase = phase
    }

    func opExtGState(_ s: CGPDFScannerRef) {
        guard let name = popName(s), let obj = resource("ExtGState", name), let d = PDFObj.asDict(obj) else { return }
        if let v = PDFObj.number(d, "LW") { gs.lineWidth = v }
        if let v = PDFObj.int(d, "LC") { gs.cap = v == 1 ? .round : v == 2 ? .square : .butt }
        if let v = PDFObj.int(d, "LJ") { gs.join = v == 1 ? .round : v == 2 ? .bevel : .miter }
        if let v = PDFObj.number(d, "ML") { gs.miter = v }
        if let da = PDFObj.array(d, "D"), CGPDFArrayGetCount(da) == 2, let arr = PDFObj.arrayElement(da, 0) {
            let dash = PDFObj.numbers(arr)
            gs.dash = dash.allSatisfy({ $0 == 0 }) ? [] : (dash.count % 2 == 1 ? dash + dash : dash)
            gs.dashPhase = PDFObj.numberElement(da, 1) ?? 0
        }
        if let v = PDFObj.number(d, "CA") { gs.strokeAlpha = v }
        if let v = PDFObj.number(d, "ca") { gs.fillAlpha = v }
        if let fa = PDFObj.array(d, "Font"), CGPDFArrayGetCount(fa) == 2, let fd = PDFObj.dictElement(fa, 0) {
            gs.font = font(for: fd); gs.fontSize = PDFObj.numberElement(fa, 1) ?? gs.fontSize
        }
        if PDFObj.dict(d, "SMask") != nil { note(.otherLoss, "A soft mask was ignored") }
        if let bm = PDFObj.name(d, "BM"), bm != "Normal", bm != "Compatible" { note(.otherLoss, "The \(bm) blend mode was drawn as Normal") }
    }

    // MARK: Paths

    func transformPoint(_ x: Double, _ y: Double) -> VectorPoint { gs.ctm.apply(VectorPoint(x, y)) }

    func opMove(_ s: CGPDFScannerRef) {
        guard let v = popNumbers(s, 2) else { return }
        let p = transformPoint(v[0], v[1])
        path.append(.move(p)); current = p; subpathStart = p
    }

    func opLine(_ s: CGPDFScannerRef) {
        guard let v = popNumbers(s, 2) else { return }
        let p = transformPoint(v[0], v[1])
        if path.isEmpty { path.append(.move(p)); subpathStart = p } else { path.append(.line(p)) }
        current = p
    }

    func opCurve(_ s: CGPDFScannerRef, kind: Int) {
        guard let v = popNumbers(s, kind == 0 ? 6 : 4) else { return }
        let c1: VectorPoint, c2: VectorPoint, end: VectorPoint
        switch kind {
        case 0: c1 = transformPoint(v[0], v[1]); c2 = transformPoint(v[2], v[3]); end = transformPoint(v[4], v[5])
        case 1: c1 = current; c2 = transformPoint(v[0], v[1]); end = transformPoint(v[2], v[3])
        default: c1 = transformPoint(v[0], v[1]); end = transformPoint(v[2], v[3]); c2 = end
        }
        if path.isEmpty { path.append(.move(c1)); subpathStart = c1 }
        path.append(.cubic(c1, c2, end)); current = end
    }

    func opClose() { if !path.isEmpty { path.append(.close); current = subpathStart } }

    func opRect(_ s: CGPDFScannerRef) {
        guard let v = popNumbers(s, 4) else { return }
        let x = v[0], y = v[1], w = v[2], h = v[3]
        let a = transformPoint(x, y), b = transformPoint(x + w, y), c = transformPoint(x + w, y + h), d = transformPoint(x, y + h)
        path.append(contentsOf: [.move(a), .line(b), .line(c), .line(d), .close])
        current = a; subpathStart = a
    }

    // MARK: Colour operators

    func setDevice(_ s: CGPDFScannerRef, stroke: Bool, space: PDFColourSpace, count: Int) {
        guard let v = popNumbers(s, count) else { return }
        if stroke { gs.strokeSpace = space; gs.strokeComps = v; gs.strokePattern = nil } else { gs.fillSpace = space; gs.fillComps = v; gs.fillPattern = nil }
    }

    func opSetSpace(_ s: CGPDFScannerRef, stroke: Bool) {
        guard let name = popName(s), let space = colourSpace(named: name) else { return }
        if stroke { gs.strokeSpace = space; gs.strokeComps = space.initial; gs.strokePattern = nil }
        else { gs.fillSpace = space; gs.fillComps = space.initial; gs.fillPattern = nil }
    }

    func opSetColour(_ s: CGPDFScannerRef, stroke: Bool) {
        let space = stroke ? gs.strokeSpace : gs.fillSpace
        var pattern: String?
        if space.isPattern { pattern = popName(s) }
        // Exactly the space's component count: popping past the operands makes CGPDFScanner log a stack underflow.
        let count = space.isPattern ? (space.kind.patternBase?.initial.count ?? 0) : space.initial.count
        let values = count > 0 ? popNumbers(s, count) ?? [] : []
        if stroke { if !values.isEmpty || pattern != nil { gs.strokeComps = values }; gs.strokePattern = pattern }
        else { if !values.isEmpty || pattern != nil { gs.fillComps = values }; gs.fillPattern = pattern }
    }

    func colour(space: PDFColourSpace, comps: [Double], alpha: Double) -> VectorColour {
        var c = space.toRGB(comps.isEmpty ? space.initial : comps)
        c.alpha = alpha
        return c
    }

    // MARK: Painting

    enum FillPaint {
        case none
        case paint(VectorPaint)
        case skewed(VectorPaint, VectorTransform)
        case tiles([VectorNode])
    }

    /// A flat stand-in for a gradient: its first colour.
    static func firstColour(_ paint: VectorPaint) -> VectorPaint? {
        switch paint {
        case .solid: return paint
        case .linear(_, _, let s), .radial(_, _, let s): return s.first.map { .solid($0.colour) }
        case .rasterised: return nil
        }
    }

    func paint(fill: Bool, stroke: Bool, rule: FillRule, close: Bool) {
        defer { path = []; pendingClip = false }
        if close, !path.isEmpty { path.append(.close) }
        let segments = path
        if fill || stroke, !segments.isEmpty {
            var strokeSpec: VectorStroke?
            if stroke {
                var paintValue: VectorPaint?
                if gs.strokeSpace.isPattern {
                    let outcome = patternPaint(name: gs.strokePattern, comps: gs.strokeComps, space: gs.strokeSpace, alpha: gs.strokeAlpha, bounds: segments.cgPath.boundingBoxOfPath)
                    switch outcome {
                    case .paint(let p), .skewed(let p, _): paintValue = PDFInterpreter.firstColour(p)
                    case .tiles, .none: break
                    }
                } else { paintValue = .solid(colour(space: gs.strokeSpace, comps: gs.strokeComps, alpha: gs.strokeAlpha)) }
                if let paintValue {
                    let scale = gs.ctm.lengthScale
                    strokeSpec = VectorStroke(paint: paintValue, width: max(gs.lineWidth * scale, 0), dash: gs.dash.map { $0 * scale }, dashPhase: gs.dashPhase * scale,
                                              cap: gs.cap, join: gs.join, miterLimit: gs.miter)
                }
            }
            var fillPaint = FillPaint.none
            if fill {
                if gs.fillSpace.isPattern {
                    fillPaint = patternPaint(name: gs.fillPattern, comps: gs.fillComps, space: gs.fillSpace, alpha: gs.fillAlpha, bounds: segments.cgPath.boundingBoxOfPath)
                } else { fillPaint = .paint(.solid(colour(space: gs.fillSpace, comps: gs.fillComps, alpha: gs.fillAlpha))) }
            }
            switch fillPaint {
            case .none: if let strokeSpec { emit(.path(segments, fill: nil, stroke: strokeSpec, rule: rule)) }
            case .paint(let p): emit(.path(segments, fill: p, stroke: strokeSpec, rule: rule))
            case .skewed(let p, let m):
                if let inverse = m.inverted { emit(.group([.path(segments.transformed(by: inverse), fill: p, stroke: nil, rule: rule)], transform: m, clip: nil, opacity: 1)) }
                if let strokeSpec { emit(.path(segments, fill: nil, stroke: strokeSpec, rule: rule)) }
            case .tiles(let tiles):
                if !tiles.isEmpty { emit(.group(tiles, transform: .identity, clip: segments, opacity: 1)) }
                if let strokeSpec { emit(.path(segments, fill: nil, stroke: strokeSpec, rule: rule)) }
            }
        }
        if pendingClip { openLevel(Level(clip: segments, opacity: 1, nodes: [])) }
    }

    // MARK: Patterns and shadings

    func patternPaint(name: String?, comps: [Double], space: PDFColourSpace, alpha: Double, bounds: CGRect) -> FillPaint {
        guard let name, let obj = resource("Pattern", name) else { return .none }
        var dict: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        if let st = PDFObj.asStream(obj) { stream = st; dict = PDFObj.streamDictionary(st) } else { dict = PDFObj.asDict(obj) }
        guard let d = dict else { return .none }
        let matrixValues = PDFObj.numbers(d, "Matrix") ?? [1, 0, 0, 1, 0, 0]
        let matrix = matrixValues.count == 6 ? VectorTransform(a: matrixValues[0], b: matrixValues[1], c: matrixValues[2], d: matrixValues[3], tx: matrixValues[4], ty: matrixValues[5]) : .identity
        let toPage = matrix.then(baseCTMs.last ?? pageBase)
        if PDFObj.int(d, "PatternType") == 2 {
            var shading = PDFObj.dict(d, "Shading")
            if shading == nil, let st = PDFObj.stream(d, "Shading") { shading = PDFObj.streamDictionary(st) }
            guard let shading else { return .none }
            if let egs = PDFObj.dict(d, "ExtGState"), PDFObj.dict(egs, "SMask") != nil { note(.otherLoss, "A soft mask was ignored") }
            guard let result = shadingPaint(shading, alpha: alpha) else { return .none }
            if toPage.isSimilarity { return .paint(map(result, by: toPage)) }
            return .skewed(result, toPage)
        }
        guard let stream, PDFObj.int(d, "PatternType") == 1 else { return .none }
        return .tiles(tilingNodes(stream, dict: d, matrix: toPage, comps: comps, space: space, alpha: alpha, bounds: bounds))
    }

    func map(_ paint: VectorPaint, by m: VectorTransform) -> VectorPaint {
        switch paint {
        case .linear(let a, let b, let s): return .linear(from: m.apply(a), to: m.apply(b), stops: s)
        case .radial(let c, let r, let s): return .radial(centre: m.apply(c), radius: r * m.lengthScale, stops: s)
        default: return paint
        }
    }

    func tilingNodes(_ stream: CGPDFStreamRef, dict d: CGPDFDictionaryRef, matrix: VectorTransform, comps: [Double], space: PDFColourSpace, alpha: Double, bounds: CGRect) -> [VectorNode] {
        guard let bbox = PDFObj.numbers(d, "BBox"), bbox.count == 4, var xstep = PDFObj.number(d, "XStep"), var ystep = PDFObj.number(d, "YStep"), formDepth < 8 else { return [] }
        if xstep == 0 { xstep = bbox[2] - bbox[0] }
        if ystep == 0 { ystep = bbox[3] - bbox[1] }
        guard xstep != 0, ystep != 0 else { return [] }
        let uncoloured = PDFObj.int(d, "PaintType") == 2
        // Render the cell once in pattern space.
        let outerLevels = levels, outerGS = gs, outerSaved = saved, outerPath = path, outerPending = pendingClip
        levels = [Level(clip: nil, opacity: 1, nodes: [])]
        saved = []; path = []; pendingClip = false
        var cell = PDFGState(ctm: .identity)
        if uncoloured, let base = space.kind.patternBase { cell.fillSpace = base; cell.fillComps = comps; cell.strokeSpace = base; cell.strokeComps = comps }
        cell.fillAlpha = alpha; cell.strokeAlpha = alpha
        gs = cell
        let cs = CGPDFContentStreamCreateWithStream(stream, PDFObj.dict(d, "Resources") ?? d, streams.last!)
        streams.append(cs); baseCTMs.append(.identity); formDepth += 1
        scan(cs)
        formDepth -= 1; baseCTMs.removeLast(); streams.removeLast()
        while levels.count > 1 { closeLevel() }
        let content = levels[0].nodes
        levels = outerLevels; gs = outerGS; saved = outerSaved; path = outerPath; pendingClip = outerPending
        guard !content.isEmpty, let inverse = matrix.inverted else { return [] }

        let bx = Double(bounds.minX), by = Double(bounds.minY), bw = Double(bounds.width), bh = Double(bounds.height)
        let corners = [VectorPoint(bx, by), VectorPoint(bx + bw, by), VectorPoint(bx, by + bh), VectorPoint(bx + bw, by + bh)].map { inverse.apply($0) }
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!, minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        // Tile indices are counted in Double first: a tiny step or a degenerate matrix gives numbers no Int holds (or NaN,
        // which fails the test too).
        let i0 = floor((minX - bbox[2]) / xstep), i1 = ceil((maxX - bbox[0]) / xstep)
        let j0 = floor((minY - bbox[3]) / ystep), j1 = ceil((maxY - bbox[1]) / ystep)
        let lo0 = min(i0, i1), hi0 = max(i0, i1), lo1 = min(j0, j1), hi1 = max(j0, j1)
        guard max(hi0 - lo0, 1) * max(hi1 - lo1, 1) <= 20_000, abs(lo0) < 1e9, abs(lo1) < 1e9 else {
            note(.shadingRasterised, "A pattern with too many tiles was left out"); return []
        }
        let clip = PathBuilder.rect(x: bbox[0], y: bbox[1], width: bbox[2] - bbox[0], height: bbox[3] - bbox[1])
        var out: [VectorNode] = []
        for j in Int(lo1)..<max(Int(hi1), Int(lo1) + 1) {
            for i in Int(lo0)..<max(Int(hi0), Int(lo0) + 1) {
                let t = VectorTransform.translation(Double(i) * xstep, Double(j) * ystep).then(matrix)
                out.append(.group(content, transform: t, clip: clip, opacity: 1))
            }
        }
        return out
    }

    func shadingColourSpace(_ d: CGPDFDictionaryRef) -> PDFColourSpace? {
        guard let obj = PDFObj.object(d, "ColorSpace") else { return nil }
        return PDFColourSpace.parse(obj, lookup: { [unowned self] n in self.resource("ColorSpace", n) })
    }

    func shadingPaint(_ d: CGPDFDictionaryRef, alpha: Double) -> VectorPaint? {
        guard let type = PDFObj.int(d, "ShadingType"), let space = shadingColourSpace(d) else { return nil }
        guard type == 2 || type == 3 else {
            note(.shadingRasterised, type == 1 ? "A function-based shading was flattened to one colour" : "A mesh gradient was flattened to one colour")
            var c = space.toRGB(PDFObj.numbers(d, "Background") ?? space.initial)
            c.alpha = alpha
            return .solid(c)
        }
        guard let coords = PDFObj.numbers(d, "Coords"), let fnObject = PDFObj.object(d, "Function"), let fn = PDFFunction.parse(fnObject) else { return nil }
        let domain = PDFObj.numbers(d, "Domain") ?? [0, 1]
        guard domain.count >= 2 else { return nil }
        let n = 48
        var stops: [GradientStop] = []
        for k in 0...n {
            let t = Double(k) / Double(n)
            var c = space.toRGB(fn.eval([domain[0] + t * (domain[1] - domain[0])]))
            c.alpha = alpha
            stops.append(GradientStop(offset: t, colour: c))
        }
        stops = PDFInterpreter.simplified(stops)
        if type == 2, coords.count >= 4 { return .linear(from: VectorPoint(coords[0], coords[1]), to: VectorPoint(coords[2], coords[3]), stops: stops) }
        guard coords.count >= 6 else { return nil }
        let r0 = coords[2], r1 = coords[5]
        if coords[0] != coords[3] || coords[1] != coords[4] { note(.shadingRasterised, "A radial gradient with different centres was drawn around its end circle") }
        guard r1 > 0 else { return nil }
        var mapped = stops
        if r0 > 0 {
            mapped = stops.map { GradientStop(offset: min(1, (r0 + $0.offset * (r1 - r0)) / r1), colour: $0.colour) }
            mapped.insert(GradientStop(offset: 0, colour: stops[0].colour), at: 0)
        }
        return .radial(centre: VectorPoint(coords[3], coords[4]), radius: r1, stops: mapped)
    }

    /// Drops stops that a straight line between their neighbours reproduces within a fraction of a colour step.
    static func simplified(_ stops: [GradientStop]) -> [GradientStop] {
        guard stops.count > 2 else { return stops }
        var out = [stops[0]]
        var anchor = 0
        for k in 1..<(stops.count - 1) {
            let a = stops[anchor], b = stops[k + 1]
            var ok = true
            for m in (anchor + 1)...k {
                let t = (stops[m].offset - a.offset) / max(b.offset - a.offset, 1e-9)
                let s = stops[m].colour
                let e = [a.colour.red + (b.colour.red - a.colour.red) * t - s.red, a.colour.green + (b.colour.green - a.colour.green) * t - s.green,
                         a.colour.blue + (b.colour.blue - a.colour.blue) * t - s.blue, a.colour.alpha + (b.colour.alpha - a.colour.alpha) * t - s.alpha]
                if e.contains(where: { abs($0) > 0.004 }) { ok = false; break }
            }
            if !ok { out.append(stops[k]); anchor = k }
        }
        out.append(stops[stops.count - 1])
        return out
    }

    func opShading(_ s: CGPDFScannerRef) {
        guard let name = popName(s), let obj = resource("Shading", name) else { return }
        var dict: CGPDFDictionaryRef?
        if let st = PDFObj.asStream(obj) { dict = PDFObj.streamDictionary(st) } else { dict = PDFObj.asDict(obj) }
        guard let d = dict, let result = shadingPaint(d, alpha: gs.fillAlpha) else { return }
        let region = clipBounds()
        let rect = PathBuilder.rect(x: Double(region.minX), y: Double(region.minY), width: Double(region.width), height: Double(region.height))
        if gs.ctm.isSimilarity { emit(.path(rect, fill: map(result, by: gs.ctm), stroke: nil)) }
        else if let inverse = gs.ctm.inverted {
            emit(.group([.path(rect.transformed(by: inverse), fill: result, stroke: nil)], transform: gs.ctm, clip: nil, opacity: 1))
        }
    }

    /// The tightest bounds known for what can be painted now (innermost clip, else the page).
    func clipBounds() -> CGRect {
        for level in levels.reversed() { if let clip = level.clip, let b = clip.controlBounds { return b.insetBy(dx: -1, dy: -1) } }
        return CGRect(x: 0, y: 0, width: size.width, height: size.height)
    }

    // MARK: XObjects

    func opDo(_ s: CGPDFScannerRef) {
        guard let name = popName(s), let obj = resource("XObject", name), let stream = PDFObj.asStream(obj), let d = PDFObj.streamDictionary(stream) else { return }
        switch PDFObj.name(d, "Subtype") {
        case "Image": drawImage(stream)
        case "Form": drawForm(stream, dict: d)
        default: break
        }
    }

    func drawImage(_ stream: CGPDFStreamRef) {
        let key = pointerKey(stream)
        var asset = imageCache[key]
        if asset == nil {
            let fill = colour(space: gs.fillSpace, comps: gs.fillComps, alpha: gs.fillAlpha)
            asset = PDFImageDecoder.decode(stream, lookup: { [unowned self] n in self.resource("ColorSpace", n) }, fill: fill)
            if let a = asset, PDFObj.streamDictionary(stream).flatMap({ PDFObj.bool($0, "ImageMask") }) != true, imageCache.count < 64 { imageCache[key] = a }
        }
        guard let asset else { note(.imagesDropped, "A picture couldn’t be decoded"); return }
        var node = VectorNode.image(asset, transform: gs.ctm)
        if gs.fillAlpha < 0.999 { node = VectorNode.group([node], transform: .identity, clip: nil, opacity: gs.fillAlpha) }
        emit(node)
    }

    func drawForm(_ stream: CGPDFStreamRef, dict d: CGPDFDictionaryRef) {
        let key = pointerKey(stream)
        guard formDepth < 14, !activeForms.contains(key) else { return }
        let matrixValues = PDFObj.numbers(d, "Matrix") ?? [1, 0, 0, 1, 0, 0]
        let outerSaved = saved.count
        opSave()
        if matrixValues.count == 6 {
            gs.ctm = VectorTransform(a: matrixValues[0], b: matrixValues[1], c: matrixValues[2], d: matrixValues[3], tx: matrixValues[4], ty: matrixValues[5]).then(gs.ctm)
        }
        let groupAlpha = gs.fillAlpha
        let startLevels = levels.count
        if PDFObj.dict(d, "Group") != nil, groupAlpha < 0.999, openLevel(Level(clip: nil, opacity: groupAlpha, nodes: [])) { gs.fillAlpha = 1; gs.strokeAlpha = 1 }
        if let bbox = PDFObj.numbers(d, "BBox"), bbox.count == 4 {
            let a = gs.ctm.apply(VectorPoint(bbox[0], bbox[1])), b = gs.ctm.apply(VectorPoint(bbox[2], bbox[1]))
            let c = gs.ctm.apply(VectorPoint(bbox[2], bbox[3])), e = gs.ctm.apply(VectorPoint(bbox[0], bbox[3]))
            openLevel(Level(clip: [.move(a), .line(b), .line(c), .line(e), .close], opacity: 1, nodes: []))
        }
        let savedPath = path, savedPending = pendingClip
        path = []; pendingClip = false
        let cs = CGPDFContentStreamCreateWithStream(stream, PDFObj.dict(d, "Resources") ?? d, streams.last!)
        streams.append(cs); baseCTMs.append(gs.ctm); formDepth += 1; activeForms.insert(key)
        scan(cs)
        activeForms.remove(key); formDepth -= 1; baseCTMs.removeLast(); streams.removeLast()
        path = savedPath; pendingClip = savedPending
        while levels.count > startLevels { closeLevel() }
        while saved.count > outerSaved + 1 { _ = saved.popLast() }
        opRestore()
    }

    // MARK: Text

    func font(for dict: CGPDFDictionaryRef) -> PDFFont {
        let key = pointerKey(dict)
        if let hit = fonts[key] { return hit }
        let f = PDFFont(dict)
        fonts[key] = f
        if PDFObj.name(dict, "Subtype") == "Type3" { note(.otherLoss, "A Type 3 font was drawn in a stand-in font") }
        if f.hadUnusableEmbedding { note(.fontsReplaced, "Fonts the converter can’t open were replaced by \(f.substitute)") }
        return f
    }

    func opFont(_ s: CGPDFScannerRef) {
        let size = popNumber(s) ?? 1
        guard let name = popName(s), let obj = resource("Font", name), let d = PDFObj.asDict(obj) else { return }
        gs.font = font(for: d)
        gs.fontSize = size
    }

    func opTd(_ s: CGPDFScannerRef, setLeading: Bool) {
        guard let v = popNumbers(s, 2) else { return }
        if setLeading { gs.leading = -v[1] }
        tlm = VectorTransform.translation(v[0], v[1]).then(tlm)
        tm = tlm
    }

    func opTm(_ s: CGPDFScannerRef) {
        guard let v = popNumbers(s, 6) else { return }
        tm = VectorTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]); tlm = tm
    }

    func nextLine() { tlm = VectorTransform.translation(0, -gs.leading).then(tlm); tm = tlm }

    func opQuote(_ s: CGPDFScannerRef) {
        var str: CGPDFStringRef?
        guard CGPDFScannerPopString(s, &str), let str, let ptr = CGPDFStringGetBytePtr(str) else { return }
        let ac = popNumber(s) ?? 0, aw = popNumber(s) ?? 0
        gs.wordSpace = aw; gs.charSpace = ac
        nextLine()
        showText([UInt8](Data(bytes: ptr, count: CGPDFStringGetLength(str))))
    }

    func opTj(_ s: CGPDFScannerRef) {
        var str: CGPDFStringRef?
        guard CGPDFScannerPopString(s, &str), let str, let ptr = CGPDFStringGetBytePtr(str) else { return }
        showText([UInt8](Data(bytes: ptr, count: CGPDFStringGetLength(str))))
    }

    func opTJ(_ s: CGPDFScannerRef) {
        var array: CGPDFArrayRef?
        guard CGPDFScannerPopArray(s, &array), let array else { return }
        var pieces: [(bytes: [UInt8]?, adjust: Double)] = []
        for i in 0..<CGPDFArrayGetCount(array) {
            if let n = PDFObj.numberElement(array, i) { pieces.append((nil, n)) }
            else if let d = PDFObj.stringElement(array, i) { pieces.append(([UInt8](d), 0)) }
        }
        showPieces(pieces)
    }

    func showText(_ bytes: [UInt8]) { showPieces([(bytes, 0)]) }

    /// A positioned glyph on its way to being emitted.
    struct PlacedGlyph { var glyph: PDFFont.Glyph; var trm: VectorTransform }

    func showPieces(_ pieces: [(bytes: [UInt8]?, adjust: Double)]) {
        guard let font = gs.font else { return }
        var placed: [PlacedGlyph] = []
        for piece in pieces {
            if let bytes = piece.bytes {
                for glyph in font.decode(bytes) {
                    let trm = VectorTransform(a: gs.fontSize * gs.hScale, b: 0, c: 0, d: gs.fontSize, tx: 0, ty: gs.rise).then(tm).then(gs.ctm)
                    placed.append(PlacedGlyph(glyph: glyph, trm: trm))
                    let tx = (glyph.width / 1000 * gs.fontSize + gs.charSpace + (glyph.isSpace ? gs.wordSpace : 0)) * gs.hScale
                    tm = VectorTransform.translation(tx, 0).then(tm)
                }
            } else {
                tm = VectorTransform.translation(-piece.adjust / 1000 * gs.fontSize * gs.hScale, 0).then(tm)
            }
        }
        if placed.isEmpty || gs.renderMode == 3 || gs.renderMode == 7 { return }
        emitGlyphs(placed, font: font)
    }

    func emitGlyphs(_ placed: [PlacedGlyph], font: PDFFont) {
        let fillPaint: VectorPaint? = gs.fillSpace.isPattern ? patternFirstColour() : .solid(colour(space: gs.fillSpace, comps: gs.fillComps, alpha: gs.fillAlpha))
        let drawFill = gs.renderMode == 0 || gs.renderMode == 2 || gs.renderMode == 4 || gs.renderMode == 6
        let drawStroke = gs.renderMode == 1 || gs.renderMode == 2 || gs.renderMode == 5 || gs.renderMode == 6
        // Filled text whose embedded program maps its characters itself stays text in that program.
        if gs.renderMode == 0, let program = font.embeddedProgram, let ct = font.embedded, let fill = fillPaint, font.mapsAsText(placed.map(\.glyph)) {
            // The subset tag ("ABCDEF+Helvetica") goes, so a target that can't embed the program still finds the font by name.
            var name = CTFontCopyPostScriptName(ct) as String
            if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 { name = String(name[name.index(after: plus)...]) }
            emitRuns(placed, fontName: name, program: program, metrics: ct, fill: fill)
            return
        }
        if font.embedded != nil {
            var outline: [PathSegment] = []
            for item in placed {
                guard let glyphPath = font.outline(item.glyph) else { continue }
                outline.append(contentsOf: glyphPath.transformed(by: item.trm))
            }
            if !outline.isEmpty {
                var strokeSpec: VectorStroke?
                if drawStroke {
                    strokeSpec = VectorStroke(paint: .solid(colour(space: gs.strokeSpace, comps: gs.strokeComps, alpha: gs.strokeAlpha)), width: gs.lineWidth * gs.ctm.lengthScale,
                                              dash: gs.dash.map { $0 * gs.ctm.lengthScale }, cap: gs.cap, join: gs.join, miterLimit: gs.miter)
                }
                emit(.path(outline, fill: drawFill ? fillPaint : nil, stroke: strokeSpec, rule: .nonZero))
                note(.textAsOutlines, "Text in embedded fonts")
            }
            return
        }
        guard let fill = fillPaint else { return }
        emitRuns(placed, fontName: font.substitute, program: nil, metrics: font.substituteCTFont, fill: fill)
    }

    func patternFirstColour() -> VectorPaint? {
        if let base = gs.fillSpace.kind.patternBase { return .solid(colour(space: base, comps: gs.fillComps, alpha: gs.fillAlpha)) }
        return .solid(.black)
    }

    /// Text in `fontName` (the embedded `program`, or a stand-in when nil): one run when the font's advances match the PDF's,
    /// else one run per word at the PDF's positions.
    func emitRuns(_ placed: [PlacedGlyph], fontName: String, program: Data?, metrics ct: CTFont, fill: VectorPaint) {
        func text(of glyphs: [PlacedGlyph]) -> String { glyphs.map(\.glyph.unicode).joined() }
        let whole = text(of: placed)
        if whole.isEmpty { note(.otherLoss, "Text without a character mapping was dropped"); return }
        var runs: [[PlacedGlyph]] = [placed]
        let pdfWidth = placed.reduce(0.0) { $0 + $1.glyph.width / 1000 }
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, whole as CFString, [kCTFontAttributeName: ct] as CFDictionary))
        let ctWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let uniform = pdfWidth > 0 && abs(ctWidth - pdfWidth) / pdfWidth < 0.04 && gs.charSpace == 0 && gs.wordSpace == 0
        if !uniform {
            runs = []
            var word: [PlacedGlyph] = []
            for g in placed {
                if g.glyph.unicode == " " || (g.glyph.unicode.isEmpty && g.glyph.isSpace) { if !word.isEmpty { runs.append(word); word = [] } }
                else { word.append(g) }
            }
            if !word.isEmpty { runs.append(word) }
        }
        for glyphs in runs {
            guard let first = glyphs.first else { continue }
            let t = text(of: glyphs)
            if t.isEmpty { continue }
            let trm = first.trm
            let s = hypot(trm.c, trm.d)
            guard s > 1e-6, s.isFinite else { continue }
            let isFlat = abs(trm.b) < 1e-9 * s && abs(trm.c) < 1e-9 * s && abs(trm.a / s - 1) < 1e-6 && trm.d > 0
            if isFlat {
                emit(.text(VectorTextRun(text: t, fontName: fontName, size: s, origin: VectorPoint(trm.tx, trm.ty), fill: fill, fontData: program)))
            } else {
                let local = VectorTransform(a: trm.a / s, b: trm.b / s, c: trm.c / s, d: trm.d / s, tx: trm.tx, ty: trm.ty)
                emit(.group([.text(VectorTextRun(text: t, fontName: fontName, size: s, origin: VectorPoint(0, 0), fill: fill, fontData: program))], transform: local, clip: nil, opacity: 1))
            }
        }
    }
}

// MARK: Operand helpers

func popNumber(_ s: CGPDFScannerRef) -> Double? {
    var v: CGPDFReal = 0
    return CGPDFScannerPopNumber(s, &v) ? Double(v) : nil
}

/// Pops `n` numbers (the last operand comes off first) and returns them in written order.
func popNumbers(_ s: CGPDFScannerRef, _ n: Int) -> [Double]? {
    var out = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) { guard let v = popNumber(s) else { return nil }; out[i] = v }
    return out
}

func popName(_ s: CGPDFScannerRef) -> String? {
    var p: UnsafePointer<Int8>?
    return CGPDFScannerPopName(s, &p) ? p.map { String(cString: $0) } : nil
}
