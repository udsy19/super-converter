import Foundation
import SuperConverterCore

// The DXF writer (formats §3.2, quality §6): a `CADDrawing` as ASCII DXF R12 through 2018. R12 is the flat form (no handles,
// POLYLINE/VERTEX, no ellipses, splines, MTEXT or hatches: those are written as lines or text); R2000 and later carry handles,
// subclass markers, a BLOCK_RECORD table and the objects layouts need. The structure follows what ezdxf writes and its auditor
// accepts.

public enum DXFVersion: Sendable {
    case r12, r14, r2000, r2004, r2007, r2010, r2013, r2018

    var code: String {
        switch self {
        case .r12: "AC1009"
        case .r14: "AC1014"
        case .r2000: "AC1015"
        case .r2004: "AC1018"
        case .r2007: "AC1021"
        case .r2010: "AC1024"
        case .r2013: "AC1027"
        case .r2018: "AC1032"
        }
    }
    var hasHandles: Bool { self != .r12 }
    var isUnicode: Bool { switch self { case .r2007, .r2010, .r2013, .r2018: true; default: false } }

    /// From the card's choice: "9"…"14", "2000"…"2018", "25", "26", "r12" (O-CAD-DWG and O-VEC option values).
    public init(option: String?) {
        switch (option ?? "2018").lowercased() {
        case "9", "10", "11", "12", "r12", "r9": self = .r12
        case "13", "14", "r14": self = .r14
        case "2000": self = .r2000
        case "2004": self = .r2004
        case "2007": self = .r2007
        case "2010": self = .r2010
        case "2013", "25": self = .r2013
        default: self = .r2018
        }
    }
}

public enum DXFWriter {
    public struct Result: Sendable {
        public var data: Data
        public var lossNotes: [LossNote]
    }

    public static func write(_ drawing: CADDrawing, version: DXFVersion = .r2018) -> Result {
        var w = Writer(drawing: drawing, version: version)
        return w.run()
    }
}

private struct Writer {
    let drawing: CADDrawing
    let v: DXFVersion
    var out = ""
    var nextHandle = 0x10
    var skipped: [String: Int] = [:]
    var layerNames: [String] = []
    var lineTypeNames: [String] = []
    var styleNames: [String] = []
    var modelRecord = ""
    var paperRecord = ""

    init(drawing: CADDrawing, version: DXFVersion) { self.drawing = drawing; self.v = version }

    // MARK: Primitives

    mutating func g(_ code: Int, _ value: String) { out += "\(code)\n\(value)\n" }
    mutating func g(_ code: Int, _ value: Int) { out += "\(code)\n\(value)\n" }
    mutating func g(_ code: Int, _ value: Double) { out += "\(code)\n\(Writer.number(value))\n" }

    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        var s = String(format: "%.10f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" || s.isEmpty ? "0" : s
    }

    mutating func handle() -> String {
        defer { nextHandle += 1 }
        return String(nextHandle, radix: 16, uppercase: true)
    }

    mutating func point(_ base: Int, _ p: CADDrawing.Point3, z: Bool = true) {
        g(base, p.x); g(base + 10, p.y)
        if z { g(base + 20, p.z) }
    }

    func enc(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "\r\n", with: "\\P").replacingOccurrences(of: "\n", with: "\\P")
        if v.isUnicode { return cleaned }
        var r = ""
        for u in cleaned.unicodeScalars {
            if u.value < 128 { r.unicodeScalars.append(u) } else { r += String(format: "\\U+%04X", u.value) }
        }
        return r
    }

    func name(_ s: String) -> String {
        // Table names cannot hold < > / \ " : ; ? * | , = `.
        String(s.map { "<>/\\\":;?|,=`".contains($0) ? "_" : $0 })
    }

    // MARK: Document

    mutating func run() -> DXFWriter.Result {
        collectNames()
        if v.hasHandles { modelRecord = handle(); paperRecord = handle() }
        header()
        if v.hasHandles { g(0, "SECTION"); g(2, "CLASSES"); g(0, "ENDSEC") }
        tables()
        blocks()
        entitiesSection()
        if v.hasHandles { objects() }
        g(0, "EOF")
        var notes: [LossNote] = []
        if !skipped.isEmpty {
            notes.append(LossNote(.otherLoss, detail: "Not written: " + skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")))
        }
        let data = Data(out.utf8)
        return DXFWriter.Result(data: data, lossNotes: notes)
    }

    mutating func collectNames() {
        var layers = Set(drawing.layers.map(\.name)), types = Set<String>(), styles = Set<String>()
        layers.insert("0")
        func visit(_ e: CADDrawing.Entity) {
            switch e {
            case .styled(let inner, let a): visit(inner); if let t = a.lineType { types.insert(t) }
            case .line(_, _, let l), .polyline(_, _, _, let l), .circle(_, _, let l), .arc(_, _, _, _, let l), .ellipse(_, _, _, _, _, let l),
                 .spline(_, _, _, _, let l), .insert(_, _, _, _, let l), .hatch(_, _, _, _, let l), .point(_, let l), .solid(_, let l),
                 .image(_, _, _, let l), .viewport(_, _, _, _, _, let l):
                layers.insert(l)
            case .text(_, _, _, _, let s, _, _, let l), .multilineText(_, _, _, _, _, _, let s, let l):
                layers.insert(l); styles.insert(s)
            }
        }
        drawing.modelSpace.forEach(visit)
        drawing.blocks.forEach { $0.entities.forEach(visit) }
        drawing.layouts.forEach { $0.entities.forEach(visit) }
        layerNames = drawing.layers.map(\.name) + layers.subtracting(drawing.layers.map(\.name)).sorted()
        for l in drawing.layers { types.insert(l.lineType) }
        let known = Set(drawing.lineTypes.map { $0.name.uppercased() })
        lineTypeNames = drawing.lineTypes.map(\.name).filter { !["CONTINUOUS", "BYLAYER", "BYBLOCK"].contains($0.uppercased()) }
            + types.filter { !known.contains($0.uppercased()) && !["CONTINUOUS", "BYLAYER", "BYBLOCK"].contains($0.uppercased()) }.sorted()
        styles.insert("STANDARD")
        let declared = Set(drawing.textStyles.map { $0.name.uppercased() })
        styleNames = drawing.textStyles.map(\.name).filter { $0.uppercased() != "STANDARD" } + styles.filter { !declared.contains($0.uppercased()) && $0.uppercased() != "STANDARD" }.sorted()
        styleNames.insert("Standard", at: 0)
    }

    mutating func header() {
        g(0, "SECTION"); g(2, "HEADER")
        g(9, "$ACADVER"); g(1, v.code)
        if v.hasHandles { g(9, "$HANDSEED"); g(5, "FFFFFF") }
        if v.isUnicode == false, v.hasHandles { g(9, "$DWGCODEPAGE"); g(3, "ANSI_1252") }
        g(9, "$INSUNITS")
        switch drawing.unit {
        case .inches: g(70, 1)
        case .feet: g(70, 2)
        case .millimetres: g(70, 4)
        case .centimetres: g(70, 5)
        case .metres: g(70, 6)
        case .unitless: g(70, 0)
        }
        g(9, "$LTSCALE"); g(40, drawing.lineTypeScale)
        g(0, "ENDSEC")
    }

    // MARK: Tables

    mutating func tableStart(_ name: String, count: Int) {
        g(0, "TABLE"); g(2, name)
        if v.hasHandles { g(5, handle()); g(100, "AcDbSymbolTable") }
        g(70, count)
    }

    mutating func record(_ type: String, _ subclass: String, _ name: String, owner: String) {
        g(0, type)
        if v.hasHandles { g(5, handle()); g(330, owner); g(100, "AcDbSymbolTableRecord"); g(100, subclass) }
        g(2, name)
    }

    mutating func tables() {
        g(0, "SECTION"); g(2, "TABLES")
        // VPORT
        if v.hasHandles {
            let owner = handle()
            g(0, "TABLE"); g(2, "VPORT"); g(5, owner); g(100, "AcDbSymbolTable"); g(70, 1)
            record("VPORT", "AcDbViewportTableRecord", "*Active", owner: owner)
            g(70, 0); g(10, 0.0); g(20, 0.0); g(11, 1.0); g(21, 1.0); g(12, 0.0); g(22, 0.0); g(13, 0.0); g(23, 0.0); g(14, 10.0); g(24, 10.0)
            g(15, 0.0); g(25, 0.0); g(16, 0.0); g(26, 0.0); g(36, 1.0); g(17, 0.0); g(27, 0.0); g(37, 0.0); g(40, 100.0); g(41, 1.0); g(42, 50.0)
            g(43, 0.0); g(44, 0.0); g(50, 0.0); g(51, 0.0); g(71, 0); g(72, 100); g(73, 1); g(74, 3); g(75, 0); g(76, 0); g(77, 0); g(78, 0)
            g(0, "ENDTAB")
        }
        // LTYPE
        let ownerLT = v.hasHandles ? handle() : ""
        g(0, "TABLE"); g(2, "LTYPE"); if v.hasHandles { g(5, ownerLT); g(100, "AcDbSymbolTable") }
        g(70, 3 + lineTypeNames.count)
        for builtin in ["ByBlock", "ByLayer", "Continuous"] {
            g(0, "LTYPE")
            if v.hasHandles { g(5, handle()); g(330, ownerLT); g(100, "AcDbSymbolTableRecord"); g(100, "AcDbLinetypeTableRecord") }
            g(2, builtin); g(70, 0); g(3, builtin == "Continuous" ? "Solid line" : ""); g(72, 65); g(73, 0); g(40, 0.0)
        }
        for name in lineTypeNames {
            let pattern = drawing.lineTypes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.pattern ?? []
            g(0, "LTYPE")
            if v.hasHandles { g(5, handle()); g(330, ownerLT); g(100, "AcDbSymbolTableRecord"); g(100, "AcDbLinetypeTableRecord") }
            g(2, self.name(name)); g(70, 0); g(3, ""); g(72, 65); g(73, pattern.count); g(40, pattern.reduce(0) { $0 + abs($1) })
            for item in pattern { g(49, item); g(74, 0) }
        }
        g(0, "ENDTAB")
        // LAYER
        let ownerLayer = v.hasHandles ? handle() : ""
        g(0, "TABLE"); g(2, "LAYER"); if v.hasHandles { g(5, ownerLayer); g(100, "AcDbSymbolTable") }
        g(70, layerNames.count)
        for n in layerNames {
            let layer = drawing.layers.first { $0.name == n } ?? CADDrawing.Layer(name: n)
            g(0, "LAYER")
            if v.hasHandles { g(5, handle()); g(330, ownerLayer); g(100, "AcDbSymbolTableRecord"); g(100, "AcDbLayerTableRecord") }
            g(2, name(n)); g(70, 0)
            g(62, layer.isVisible ? layer.colourIndex : -layer.colourIndex)
            if let t = layer.trueColour, v.hasHandles { g(420, t) }
            g(6, layer.lineType.isEmpty ? "Continuous" : name(layer.lineType))
            if v.hasHandles {
                g(370, layer.lineWeight.map { Writer.lineWeightCode($0) } ?? -3)
            }
        }
        g(0, "ENDTAB")
        // STYLE
        let ownerStyle = v.hasHandles ? handle() : ""
        g(0, "TABLE"); g(2, "STYLE"); if v.hasHandles { g(5, ownerStyle); g(100, "AcDbSymbolTable") }
        g(70, styleNames.count)
        for n in styleNames {
            let style = drawing.textStyles.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
            g(0, "STYLE")
            if v.hasHandles { g(5, handle()); g(330, ownerStyle); g(100, "AcDbSymbolTableRecord"); g(100, "AcDbTextStyleTableRecord") }
            g(2, name(n)); g(70, 0); g(40, 0.0); g(41, style?.widthFactor ?? 1); g(50, style?.oblique ?? 0); g(71, 0); g(42, 2.5)
            g(3, style?.font.isEmpty == false ? style!.font : "txt"); g(4, "")
        }
        g(0, "ENDTAB")
        if v.hasHandles {
            // VIEW, UCS: empty; APPID: ACAD; DIMSTYLE: none; BLOCK_RECORD.
            for empty in ["VIEW", "UCS"] { tableStart(empty, count: 0); g(0, "ENDTAB") }
            let ownerApp = handle()
            g(0, "TABLE"); g(2, "APPID"); g(5, ownerApp); g(100, "AcDbSymbolTable"); g(70, 1)
            record("APPID", "AcDbRegAppTableRecord", "ACAD", owner: ownerApp); g(70, 0)
            g(0, "ENDTAB")
            tableStart("DIMSTYLE", count: 0); g(0, "ENDTAB")
        } else {
            g(0, "TABLE"); g(2, "VIEW"); g(70, 0); g(0, "ENDTAB")
            g(0, "TABLE"); g(2, "UCS"); g(70, 0); g(0, "ENDTAB")
            g(0, "TABLE"); g(2, "APPID"); g(70, 1); g(0, "APPID"); g(2, "ACAD"); g(70, 0); g(0, "ENDTAB")
            g(0, "TABLE"); g(2, "DIMSTYLE"); g(70, 0); g(0, "ENDTAB")
        }
        if v.hasHandles {
            let ownerBR = handle()
            blockRecordOwner = ownerBR
            g(0, "TABLE"); g(2, "BLOCK_RECORD"); g(5, ownerBR); g(100, "AcDbSymbolTable")
            g(70, 2 + drawing.blocks.count + max(drawing.layouts.count, 1) - 1)
            blockRecord("*Model_Space", handle: modelRecord, layout: layoutHandles.model)
            blockRecord("*Paper_Space", handle: paperRecord, layout: layoutHandles.paper(0))
            for (i, _) in drawing.layouts.enumerated().dropFirst() {
                blockRecord("*Paper_Space\(i - 1)", handle: extraPaperRecords[i - 1], layout: layoutHandles.paper(i))
            }
            for b in drawing.blocks { blockRecord(name(b.name), handle: blockHandles[b.name] ?? handle(), layout: "0") }
            g(0, "ENDTAB")
        }
        g(0, "ENDSEC")
    }

    var blockRecordOwner = ""
    // Handles for objects defined before they are written (block records point at layouts and the reverse).
    lazy var layoutHandles: (model: String, paper: (Int) -> String) = {
        let model = handle()
        let paper = (0..<max(drawing.layouts.count, 1)).map { _ in handle() }
        return (model, { paper[min($0, paper.count - 1)] })
    }()
    lazy var extraPaperRecords: [String] = (0..<max(drawing.layouts.count - 1, 0)).map { _ in handle() }
    lazy var blockHandles: [String: String] = Dictionary(drawing.blocks.map { ($0.name, handle()) }, uniquingKeysWith: { a, _ in a })

    mutating func blockRecord(_ n: String, handle h: String, layout: String) {
        g(0, "BLOCK_RECORD"); g(5, h); g(330, blockRecordOwner); g(100, "AcDbSymbolTableRecord"); g(100, "AcDbBlockTableRecord")
        g(2, n)
        g(70, 0); g(280, 1); g(281, 0)
        if layout != "0" { g(340, layout) }
    }

    static let lineWeights = [0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200, 211]
    static func lineWeightCode(_ mm: Double) -> Int {
        let hundredths = Int((mm * 100).rounded())
        return lineWeights.min { abs($0 - hundredths) < abs($1 - hundredths) } ?? 25
    }

    // MARK: Blocks

    mutating func blocks() {
        g(0, "SECTION"); g(2, "BLOCKS")
        func wrap(_ name: String, record: String, base: CADDrawing.Point3, _ body: (inout Writer) -> Void, paper: Bool = false) {
            g(0, "BLOCK")
            if v.hasHandles { g(5, handle()); g(330, record); g(100, "AcDbEntity"); if paper { g(67, 1) }; g(8, "0"); g(100, "AcDbBlockBegin") }
            else { g(8, "0") }
            g(2, self.name(name)); g(70, 0); point(10, base); g(3, self.name(name)); g(1, "")
            body(&self)
            g(0, "ENDBLK")
            if v.hasHandles { g(5, handle()); g(330, record); g(100, "AcDbEntity"); if paper { g(67, 1) }; g(8, "0"); g(100, "AcDbBlockEnd") }
            else { g(8, "0") }
        }
        if v.hasHandles {
            wrap("*Model_Space", record: modelRecord, base: .init(0, 0), { _ in })
            wrap("*Paper_Space", record: paperRecord, base: .init(0, 0), { _ in }, paper: true)
            for (i, layout) in drawing.layouts.enumerated().dropFirst() {
                wrap("*Paper_Space\(i - 1)", record: extraPaperRecords[i - 1], base: .init(0, 0), { w in
                    for e in layout.entities { w.entity(e, owner: w.extraPaperRecords[i - 1], paper: true) }
                }, paper: true)
            }
            for b in drawing.blocks {
                let record = blockHandles[b.name] ?? "0"
                wrap(b.name, record: record, base: b.base) { w in for e in b.entities { w.entity(e, owner: record, paper: false) } }
            }
        } else {
            for b in drawing.blocks { wrap(b.name, record: "", base: b.base) { w in for e in b.entities { w.entity(e, owner: "", paper: false) } } }
        }
        g(0, "ENDSEC")
    }

    // MARK: Entities

    mutating func entitiesSection() {
        g(0, "SECTION"); g(2, "ENTITIES")
        for e in drawing.modelSpace { entity(e, owner: modelRecord, paper: false) }
        if let first = drawing.layouts.first {
            for e in first.entities { entity(e, owner: paperRecord, paper: true, layout: first.name) }
            if !v.hasHandles && drawing.layouts.count > 1 { skipped["layouts", default: 0] += drawing.layouts.count - 1 }
        }
        g(0, "ENDSEC")
    }

    struct EntityContext {
        var owner: String
        var paper: Bool
        var layout: String?
        var appearance: CADDrawing.Appearance?
    }

    mutating func common(_ type: String, _ subclass: String, layer: String, _ ctx: EntityContext) {
        let owner = ctx.owner, paper = ctx.paper, layout = ctx.layout, a = ctx.appearance
        g(0, type)
        if v.hasHandles { g(5, handle()); g(330, owner) }
        if v.hasHandles { g(100, "AcDbEntity") }
        if paper { g(67, 1) }
        if v.hasHandles, let layout, paper { g(410, layout) }
        g(8, name(layer))
        if let a {
            if let t = a.lineType { g(6, name(t)) }
            if let c = a.colourIndex { g(62, c) }
            if let w = a.lineWeight, v.hasHandles { g(370, w < 0 ? -2 : Writer.lineWeightCode(w)) }
            if a.lineTypeScale != 1 { g(48, a.lineTypeScale) }
            if let t = a.trueColour, v.hasHandles { g(420, t) }
        }
        if v.hasHandles, !subclass.isEmpty { g(100, subclass) }
    }

    mutating func entity(_ entity: CADDrawing.Entity, owner: String, paper: Bool, layout: String? = nil) {
        var e = entity
        var a: CADDrawing.Appearance?
        while case .styled(let inner, let appearance) = e { e = inner; a = a ?? appearance }
        let ctx = EntityContext(owner: owner, paper: paper, layout: layout, appearance: a)
        func c(_ type: String, _ sub: String, _ layer: String) { common(type, sub, layer: layer, ctx) }
        switch e {
        case .line(let p, let q, let l):
            c("LINE", "AcDbLine", l); point(10, p); point(11, q)
        case .point(let p, let l):
            c("POINT", "AcDbPoint", l); point(10, p)
        case .circle(let p, let r, let l):
            c("CIRCLE", "AcDbCircle", l); point(10, p); g(40, r)
        case .arc(let p, let r, let s, let t, let l):
            c("ARC", "AcDbCircle", l); point(10, p); g(40, r)
            if v.hasHandles { g(100, "AcDbArc") }
            g(50, s); g(51, t)
        case .polyline(let pts, let closed, let bulges, let l):
            polyline(pts, closed: closed, bulges: bulges, layer: l, ctx)
        case .ellipse(let p, let major, let ratio, let s, let t, let l):
            if v.hasHandles {
                c("ELLIPSE", "AcDbEllipse", l); point(10, p); point(11, major); g(210, 0.0); g(220, 0.0); g(230, 1.0); g(40, ratio); g(41, s); g(42, t)
            } else {
                let n = 48
                var sweep = t - s; if sweep <= 0 { sweep += 2 * .pi }
                let minor = (-major.y * ratio, major.x * ratio)
                let pts = (0...n).map { k -> CADDrawing.Point3 in
                    let u = s + sweep * Double(k) / Double(n)
                    return .init(p.x + cos(u) * major.x + sin(u) * minor.0, p.y + cos(u) * major.y + sin(u) * minor.1, p.z)
                }
                polyline(pts, closed: false, bulges: [], layer: l, ctx)
            }
        case .spline(let degree, let control, let knots, let weights, let l):
            if v.hasHandles {
                c("SPLINE", "AcDbSpline", l); g(210, 0.0); g(220, 0.0); g(230, 1.0)
                var flags = 8
                if !weights.isEmpty { flags |= 4 }
                let usedKnots = knots.count == control.count + degree + 1 ? knots : (0..<(control.count + degree + 1)).map { i in
                    i <= degree ? 0.0 : (i >= control.count ? Double(control.count - degree) : Double(i - degree))
                }
                g(70, flags); g(71, degree); g(72, usedKnots.count); g(73, control.count); g(74, 0)
                for k in usedKnots { g(40, k) }
                if !weights.isEmpty { for w in weights { g(41, w) } }
                for p in control { point(10, p) }
            } else {
                let pts = NURBS.sample(degree: degree, controls: control, knots: knots, weights: weights, samples: max(24, control.count * 8))
                polyline(pts, closed: false, bulges: [], layer: l, ctx)
            }
        case .text(let s, let p, let h, let rot, let style, let align, let wf, let l):
            c("TEXT", "AcDbText", l); point(10, p); g(40, h); g(1, enc(s)); if rot != 0 { g(50, rot) }
            if wf != 1 { g(41, wf) }
            g(7, name(style))
            let (hz, vt) = Writer.alignmentCodes(align)
            if hz != 0 || vt != 0 {
                g(72, hz); point(11, p)
                if v.hasHandles { g(100, "AcDbText") }
                g(73, vt)
            } else if v.hasHandles { g(100, "AcDbText") }
        case .multilineText(let s, let p, let h, let width, let rot, let attachment, let style, let l):
            if v.hasHandles {
                c("MTEXT", "AcDbMText", l); point(10, p); g(40, h); if width > 0 { g(41, width) }; g(71, attachment); g(72, 1)
                var rest = enc(s)
                while rest.count > 250 { let chunk = rest.prefix(250); g(3, String(chunk)); rest = String(rest.dropFirst(250)) }
                g(1, rest); g(7, name(style))
                if rot != 0 { g(50, rot) }
            } else {
                let lines = DrawingText.mtextParagraphs(s)
                for (i, line) in lines.enumerated() {
                    c("TEXT", "AcDbText", l)
                    let drop = Double(i) * h * 5 / 3, a = rot * .pi / 180
                    point(10, .init(p.x + drop * sin(a), p.y - drop * cos(a), p.z))
                    g(40, h); g(1, enc(line)); if rot != 0 { g(50, rot) }; g(7, name(style))
                }
            }
        case .insert(let block, let p, let scale, let rot, let l):
            c("INSERT", "AcDbBlockReference", l); g(2, name(block)); point(10, p)
            if scale.x != 1 || scale.y != 1 || scale.z != 1 { g(41, scale.x); g(42, scale.y); g(43, scale.z) }
            if rot != 0 { g(50, rot) }
        case .solid(let pts, let l):
            guard pts.count >= 3 else { return }
            c("SOLID", "AcDbTrace", l)
            // Vertices 1, 2, 4, 3.
            let order = pts.count == 3 ? [0, 1, 2, 2] : [0, 1, 3, 2]
            for (i, k) in order.enumerated() { point(10 + i, pts[k]) }
        case .hatch(let loops, let pattern, let solid, let lines, let l):
            hatch(loops, pattern: pattern, solid: solid, lines: lines, layer: l, ctx)
        case .image, .viewport:
            skipped[entityKind(e), default: 0] += 1
        case .styled:
            break
        }
    }

    func entityKind(_ e: CADDrawing.Entity) -> String {
        switch e { case .image: "IMAGE"; case .viewport: "VIEWPORT"; default: "entities" }
    }

    static func alignmentCodes(_ a: CADDrawing.TextAlign) -> (Int, Int) {
        switch a {
        case .baselineLeft: (0, 0)
        case .baselineCentre: (1, 0)
        case .baselineRight: (2, 0)
        case .bottomLeft: (0, 1)
        case .bottomCentre: (1, 1)
        case .bottomRight: (2, 1)
        case .middleLeft: (0, 2)
        case .middleCentre: (1, 2)
        case .middleRight: (2, 2)
        case .topLeft: (0, 3)
        case .topCentre: (1, 3)
        case .topRight: (2, 3)
        }
    }

    mutating func polyline(_ pts: [CADDrawing.Point3], closed: Bool, bulges: [Double], layer: String,
                           _ ctx: EntityContext) {
        guard pts.count >= 2 else { return }
        let is3D = pts.contains { $0.z != 0 }
        if v.hasHandles && !is3D {
            common("LWPOLYLINE", "AcDbPolyline", layer: layer, ctx)
            g(90, pts.count); g(70, closed ? 1 : 0); g(38, 0.0)
            for (i, p) in pts.enumerated() {
                g(10, p.x); g(20, p.y)
                if bulges.indices.contains(i), bulges[i] != 0 { g(42, bulges[i]) }
            }
        } else {
            common("POLYLINE", is3D ? "AcDb3dPolyline" : "AcDb2dPolyline", layer: layer, ctx)
            g(66, 1)
            point(10, .init(0, 0, 0)); g(70, (closed ? 1 : 0) | (is3D ? 8 : 0))
            for (i, p) in pts.enumerated() {
                g(0, "VERTEX")
                if v.hasHandles { g(5, handle()); g(100, "AcDbEntity"); g(8, name(layer)); g(100, is3D ? "AcDb3dPolylineVertex" : "AcDb2dVertex") } else { g(8, name(layer)) }
                point(10, p); g(70, is3D ? 32 : 0)
                if !is3D, bulges.indices.contains(i), bulges[i] != 0 { g(42, bulges[i]) }
            }
            g(0, "SEQEND")
            if v.hasHandles { g(5, handle()); g(100, "AcDbEntity"); g(8, name(layer)) } else { g(8, name(layer)) }
        }
    }

    mutating func hatch(_ loops: [[CADDrawing.Point3]], pattern: String, solid: Bool, lines: [CADDrawing.HatchLine], layer: String,
                        _ ctx: EntityContext) {
        guard v.hasHandles else {
            // R12 has no HATCH: the boundaries stay as outlines.
            for loop in loops { polyline(loop, closed: true, bulges: [], layer: layer, ctx) }
            skipped["HATCH fills", default: 0] += 1
            return
        }
        common("HATCH", "AcDbHatch", layer: layer, ctx)
        g(10, 0.0); g(20, 0.0); g(30, loops.first?.first?.z ?? 0); g(210, 0.0); g(220, 0.0); g(230, 1.0)
        g(2, solid ? "SOLID" : pattern); g(70, solid ? 1 : 0); g(71, 0)
        g(91, loops.count)
        for loop in loops {
            g(92, 3); g(72, 0); g(73, 1); g(93, loop.count)
            for p in loop { g(10, p.x); g(20, p.y) }
            g(97, 0)
        }
        g(75, 0); g(76, 1)
        if !solid {
            g(52, 0.0); g(41, 1.0); g(77, 0); g(78, lines.count)
            for l in lines {
                g(53, l.angle); g(43, l.base.x); g(44, l.base.y); g(45, l.offset.x); g(46, l.offset.y); g(79, l.dashes.count)
                for d in l.dashes { g(49, d) }
            }
        }
        g(47, 1.0); g(98, 0)
    }

    // MARK: Objects

    mutating func objects() {
        g(0, "SECTION"); g(2, "OBJECTS")
        let root = handle(), layoutDict = handle()
        g(0, "DICTIONARY"); g(5, root); g(330, "0"); g(100, "AcDbDictionary"); g(281, 1)
        g(3, "ACAD_LAYOUT"); g(350, layoutDict)
        g(0, "DICTIONARY"); g(5, layoutDict); g(330, root); g(100, "AcDbDictionary"); g(281, 1)
        var handles: [(String, String)] = []
        let model = layoutHandles.model
        handles.append(("Model", model))
        let count = max(drawing.layouts.count, 1)
        for i in 0..<count { handles.append((drawing.layouts.indices.contains(i) ? drawing.layouts[i].name : "Layout1", layoutHandles.paper(i))) }
        for (name, h) in handles { g(3, name); g(350, h) }
        for (index, (name, h)) in handles.enumerated() {
            let isModel = index == 0
            let layout = isModel || !drawing.layouts.indices.contains(index - 1) ? nil : drawing.layouts[index - 1]
            g(0, "LAYOUT"); g(5, h); g(330, layoutDict); g(100, "AcDbPlotSettings")
            g(1, ""); g(2, "none_device"); g(4, ""); g(6, "")
            let paper = layout?.paperSize ?? VectorSize(width: 420, height: 297)
            g(40, 0.0); g(41, 0.0); g(42, 0.0); g(43, 0.0); g(44, paper.width); g(45, paper.height); g(46, 0.0); g(47, 0.0); g(48, 0.0); g(49, 0.0)
            g(140, 0.0); g(141, 0.0); g(142, 1.0); g(143, 1.0); g(70, isModel ? 1712 : 688); g(72, 1); g(73, 0); g(74, 5); g(7, ""); g(75, 16)
            g(147, 1.0); g(148, 0.0); g(149, 0.0)
            g(100, "AcDbLayout"); g(1, name); g(70, 1); g(71, index); g(10, 0.0); g(20, 0.0); g(11, paper.width); g(21, paper.height)
            g(12, 0.0); g(22, 0.0); g(32, 0.0); g(14, 0.0); g(24, 0.0); g(34, 0.0); g(15, paper.width); g(25, paper.height); g(35, 0.0)
            g(146, 0.0); g(13, 0.0); g(23, 0.0); g(33, 0.0); g(16, 1.0); g(26, 0.0); g(36, 0.0); g(17, 0.0); g(27, 1.0); g(37, 0.0); g(76, 0)
            g(330, isModel ? modelRecord : (index == 1 ? paperRecord : extraPaperRecords[index - 2]))
        }
        g(0, "ENDSEC")
    }
}
