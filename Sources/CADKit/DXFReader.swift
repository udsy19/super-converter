import Foundation
import SuperConverterCore

// The DXF reader (formats §3.2): ASCII and binary DXF R12–2018 into a `CADDrawing`. Written against the published DXF
// reference, with ezdxf (MIT) as the behavioural reference for the awkward corners: OCS, polyface meshes, HATCH paths, array
// INSERTs, paper-space layouts.

struct DXFReadResult {
    var drawing: CADDrawing
    var lossNotes: [LossNote]
}

enum DXFReader {
    typealias Point3 = CADDrawing.Point3
    typealias Entity = CADDrawing.Entity
    /// The most copies one array INSERT (groups 70 × 71) makes.
    static let maxArrayCells = 10_000

    static func read(_ data: Data) throws -> DXFReadResult {
        let groups = DXFGroups.parse(data)
        var sections: [String: [DXFRecord]] = [:]
        var header: [String: [DXFGroup]] = [:]
        let all = dxfRecords(groups[...])
        var currentName: String?
        for record in all {
            switch record.type {
            case "SECTION":
                currentName = record.string(2)?.trimmingCharacters(in: .whitespaces)
                if currentName == "HEADER" { header = headerVariables(record.groups) }
                if let name = currentName { sections[name] = [] }
            case "ENDSEC": currentName = nil
            case "EOF": break
            default: if let name = currentName { sections[name, default: []].append(record) }
            }
        }
        guard sections["ENTITIES"] != nil || sections["BLOCKS"] != nil else { throw ConversionError.damaged("dxf") }

        var reader = Reader()
        reader.readHeader(header)
        reader.readTables(sections["TABLES"] ?? [])
        reader.readBlocks(sections["BLOCKS"] ?? [])
        reader.readObjects(sections["OBJECTS"] ?? [])
        reader.readEntities(sections["ENTITIES"] ?? [])
        return reader.finish()
    }

    private static func headerVariables(_ groups: [DXFGroup]) -> [String: [DXFGroup]] {
        var variables: [String: [DXFGroup]] = [:]
        var name: String?
        for group in groups {
            if group.code == 9 { name = group.text.trimmingCharacters(in: .whitespaces); variables[name!] = [] }
            else if let name { variables[name]?.append(group) }
        }
        return variables
    }

    // MARK: Reader state

    private struct Reader {
        var drawing = CADDrawing()
        var loss: [String: Int] = [:]
        var layoutNames: [String] = []
        var layoutPaper: [String: VectorSize] = [:]
        /// Layout name → the block record holding its entities (R2000+).
        var layoutBlockHandle: [String: String] = [:]
        var blockRecordName: [String: String] = [:]
        var imageDefs: [String: String] = [:]
        var blockEntities: [String: [Entity]] = [:]
        var blockBases: [String: Point3] = [:]
        var blockOrder: [String] = []
        var paperEntities: [(layout: String?, entity: Entity)] = []

        mutating func readHeader(_ h: [String: [DXFGroup]]) {
            if let v = h["$ACADVER"]?.first { drawing.sourceVersion = v.text.trimmingCharacters(in: .whitespaces) }
            if let v = h["$INSUNITS"]?.first {
                switch v.int {
                case 1: drawing.unit = .inches
                case 2: drawing.unit = .feet
                case 4: drawing.unit = .millimetres
                case 5: drawing.unit = .centimetres
                case 6: drawing.unit = .metres
                default: drawing.unit = .unitless
                }
            }
            if let v = h["$LTSCALE"]?.first, v.double > 0 { drawing.lineTypeScale = v.double }
        }

        // MARK: Tables

        mutating func readTables(_ records: [DXFRecord]) {
            var table = ""
            for record in records {
                switch record.type {
                case "TABLE": table = record.string(2) ?? ""
                case "LAYER":
                    let flags = record.int(70)
                    let colour = record.int(62, 7)
                    let weight = record.int(370, -3)
                    drawing.layers.append(.init(
                        name: record.string(2) ?? "0", colourIndex: min(max(abs(colour), 1), 255),
                        trueColour: record.has(420) ? record.int(420) & 0xFFFFFF : nil,
                        lineType: record.string(6) ?? "CONTINUOUS", lineWeight: weight >= 0 ? Double(weight) / 100 : nil,
                        isVisible: colour >= 0 && flags & 1 == 0))
                case "LTYPE":
                    // Complex linetypes carry text or shapes (group 74 flags on the element); only the dash lengths are kept.
                    drawing.lineTypes.append(.init(name: record.string(2) ?? "", pattern: record.all(49).map(\.double)))
                case "STYLE":
                    drawing.textStyles.append(.init(name: record.string(2) ?? "", font: record.string(3) ?? "",
                                                    widthFactor: record.double(41, 1) > 0 ? record.double(41, 1) : 1,
                                                    oblique: record.double(50)))
                case "BLOCK_RECORD" where table == "BLOCK_RECORD":
                    if let handle = record.string(5), let name = record.string(2) { blockRecordName[handle.uppercased()] = name }
                default: break
                }
            }
        }

        // MARK: Blocks

        mutating func readBlocks(_ records: [DXFRecord]) {
            var name: String?
            var body: [DXFRecord] = []
            func close(_ reader: inout Reader) {
                guard let n = name else { return }
                reader.blockEntities[n] = reader.convert(body[...]).map(\.entity)
                body = []
            }
            for record in records {
                switch record.type {
                case "BLOCK":
                    name = record.string(2) ?? record.string(3)
                    if let n = name {
                        blockBases[n] = point(record, 10)
                        if !blockOrder.contains(n) { blockOrder.append(n) }
                    }
                    body = []
                case "ENDBLK":
                    close(&self); name = nil
                default: if name != nil { body.append(record) }
                }
            }
        }

        // MARK: Objects (layouts, image definitions)

        mutating func readObjects(_ records: [DXFRecord]) {
            for record in records {
                switch record.type {
                case "LAYOUT":
                    var layoutName: String?
                    var inLayout = false
                    for g in record.groups {
                        if g.code == 100 { inLayout = g.text == "AcDbLayout" }
                        else if g.code == 1 && inLayout { layoutName = g.text }
                    }
                    guard let layoutName, layoutName.caseInsensitiveCompare("Model") != .orderedSame else { continue }
                    layoutNames.append(layoutName)
                    if let handle = record.all(330).last?.text { layoutBlockHandle[layoutName] = handle.uppercased() }
                    var w = record.double(44), h = record.double(45)
                    if record.int(72) == 0 && w > 0 { w *= 25.4; h *= 25.4 }
                    if record.int(73) & 1 == 1 { swap(&w, &h) }
                    if w > 0 && h > 0 && (w * h).isFinite { layoutPaper[layoutName] = VectorSize(width: w, height: h) }
                case "IMAGEDEF":
                    if let handle = record.string(5), let path = record.string(1) { imageDefs[handle.uppercased()] = path }
                default: break
                }
            }
        }

        // MARK: Entities

        mutating func readEntities(_ records: [DXFRecord]) {
            for item in convert(records[...]) {
                if item.paper { paperEntities.append((item.layout, item.entity)) } else { drawing.modelSpace.append(item.entity) }
            }
        }

        struct Converted { var entity: Entity; var paper: Bool; var layout: String? }

        mutating func convert(_ records: ArraySlice<DXFRecord>) -> [Converted] {
            var out: [Converted] = []
            var i = records.startIndex
            while i < records.endIndex {
                let record = records[i]
                i += 1
                var produced: [Entity] = []
                switch record.type {
                case "POLYLINE":
                    var vertices: [DXFRecord] = []
                    while i < records.endIndex, records[i].type == "VERTEX" { vertices.append(records[i]); i += 1 }
                    if i < records.endIndex, records[i].type == "SEQEND" { i += 1 }
                    produced = polyline(record, vertices)
                case "INSERT":
                    var attributes: [DXFRecord] = []
                    if record.int(66) == 1 {
                        while i < records.endIndex, records[i].type == "ATTRIB" { attributes.append(records[i]); i += 1 }
                        if i < records.endIndex, records[i].type == "SEQEND" { i += 1 }
                    }
                    produced = insert(record, attributes)
                case "SEQEND", "VERTEX", "ATTDEF", "ENDBLK": break
                default: produced = entity(record)
                }
                let paper = record.int(67) == 1
                let layout = record.string(410)
                for e in produced { out.append(Converted(entity: styled(e, record), paper: paper, layout: layout)) }
            }
            return out
        }

        mutating func entity(_ r: DXFRecord) -> [Entity] {
            let layer = r.string(8) ?? "0"
            switch r.type {
            case "LINE":
                return [.line(point(r, 10), point(r, 11), layer: layer)]
            case "POINT":
                return [.point(point(r, 10), layer: layer)]
            case "CIRCLE":
                return arcLike(r, layer: layer, circle: true)
            case "ARC":
                return arcLike(r, layer: layer, circle: false)
            case "LWPOLYLINE":
                return lwPolyline(r, layer: layer)
            case "ELLIPSE":
                return [.ellipse(centre: point(r, 10), majorAxis: point(r, 11), ratio: r.double(40, 1),
                                 startParameter: r.double(41, 0), endParameter: r.double(42, 2 * .pi), layer: layer)]
            case "SPLINE":
                return spline(r, layer: layer)
            case "TEXT":
                return text(r, layer: layer)
            case "MTEXT":
                return mtext(r, layer: layer)
            case "HATCH":
                return hatch(r, layer: layer)
            case "DIMENSION":
                guard let block = r.string(2), !block.isEmpty else { return [] }
                return [.insert(block: block, at: Point3(0, 0), scale: Point3(1, 1, 1), rotation: 0, layer: layer)]
            case "LEADER":
                return leader(r, layer: layer)
            case "MLEADER":
                return mleader(r, layer: layer)
            case "SOLID", "TRACE":
                // Vertices 1, 2, 4, 3 make the outline.
                let v = (10...13).map { point(r, $0) }
                let ocs = OCS(r.extrusion)
                var outline = [v[0], v[1], v[3], v[2]].map { ocs.world($0) }
                if outline[2] == outline[3] { outline.removeLast() }
                return [.solid(outline, layer: layer)]
            case "3DFACE":
                let v = (10...13).map { point(r, $0) }
                var pts = v
                if pts[2] == pts[3] { pts.removeLast() }
                return [.polyline(pts, closed: true, bulges: [], layer: layer)]
            case "IMAGE":
                guard let handle = r.string(340)?.uppercased(), let path = imageDefs[handle] else { return [] }
                let u = point(r, 11), size = (r.double(13), r.double(23))
                return [.image(path: path, at: point(r, 10), size: VectorSize(width: hypot(u.x, u.y) * size.0, height: hypot(u.x, u.y) * size.1), layer: layer)]
            case "VIEWPORT":
                // The first viewport (id 1) is the paper-space window itself; status 0 is off.
                guard r.int(69) != 1, r.int(68) > 0 else { return [] }
                return [.viewport(centre: point(r, 10), width: r.double(40), height: r.double(41), viewCentre: point(r, 12),
                                  viewHeight: r.double(45), layer: layer)]
            default:
                noteLoss(r.type); return []
            }
        }

        mutating func noteLoss(_ type: String) { loss[type, default: 0] += 1 }

        // MARK: Geometry helpers

        func point(_ r: DXFRecord, _ base: Int) -> Point3 {
            let p = r.point(base)
            return Point3(p.x, p.y, p.z)
        }

        func styled(_ e: Entity, _ r: DXFRecord) -> Entity {
            var a = CADDrawing.Appearance()
            var any = false
            if r.has(62) { let c = r.int(62); if c != 256 { a.colourIndex = abs(c); any = true } }
            if r.has(420) { a.trueColour = r.int(420) & 0xFFFFFF; any = true }
            if let lt = r.string(6)?.trimmingCharacters(in: .whitespaces), lt.uppercased() != "BYLAYER" { a.lineType = lt; any = true }
            if r.has(370) { let w = r.int(370); if w != -1 { a.lineWeight = w >= 0 ? Double(w) / 100 : -2; any = true } }
            if r.has(48), r.double(48) > 0 { a.lineTypeScale = r.double(48); any = true }
            return any ? .styled(e, a) : e
        }

        func arcLike(_ r: DXFRecord, layer: String, circle: Bool) -> [Entity] {
            let ocs = OCS(r.extrusion)
            let c = point(r, 10), radius = r.double(40)
            var start = circle ? 0 : r.double(50), end = circle ? 360 : r.double(51)
            if ocs.isIdentity {
                return [circle ? .circle(centre: c, radius: radius, layer: layer)
                               : .arc(centre: c, radius: radius, startAngle: start, endAngle: end, layer: layer)]
            }
            let centre = ocs.world(c)
            if ocs.isFlipped {
                if circle { return [.circle(centre: centre, radius: radius, layer: layer)] }
                (start, end) = (180 - end, 180 - start)
                return [.arc(centre: centre, radius: radius, startAngle: start, endAngle: end, layer: layer)]
            }
            // Any other normal: the curve is tessellated in world space, one point per 5° of a sweep of at most a full turn.
            var sweep = circle ? 360 : (end - start).truncatingRemainder(dividingBy: 360)
            if sweep <= 0 { sweep += 360 }
            end = start + sweep
            let n = max(12, Int(sweep / 5))
            let pts = (0...n).map { k -> Point3 in
                let a = (start + (end - start) * Double(k) / Double(n)) * .pi / 180
                return ocs.world(Point3(c.x + radius * cos(a), c.y + radius * sin(a), c.z))
            }
            return [.polyline(pts, closed: circle, bulges: [], layer: layer)]
        }

        func lwPolyline(_ r: DXFRecord, layer: String) -> [Entity] {
            let ocs = OCS(r.extrusion)
            let elevation = r.double(38)
            var pts: [Point3] = [], bulges: [Double] = []
            for g in r.groups {
                switch g.code {
                case 10: pts.append(Point3(g.double, 0, elevation)); bulges.append(0)
                case 20: if !pts.isEmpty { pts[pts.count - 1].y = g.double }
                case 42: if !bulges.isEmpty { bulges[bulges.count - 1] = g.double }
                default: break
                }
            }
            guard pts.count >= 2 else { return [] }
            let sign: Double = ocs.isFlipped ? -1 : 1
            return [.polyline(pts.map { ocs.world($0) }, closed: r.int(70) & 1 == 1, bulges: bulges.map { $0 * sign }, layer: layer)]
        }

        func polyline(_ r: DXFRecord, _ vertices: [DXFRecord]) -> [Entity] {
            let layer = r.string(8) ?? "0"
            let flags = r.int(70)
            let ocs = OCS(r.extrusion)
            if flags & 64 != 0 {
                // Polyface mesh: position vertices (flag 64) then face records (flag 128) indexing them 1-based.
                var positions: [Point3] = []
                var faces: [[Int]] = []
                for v in vertices {
                    let vf = v.int(70)
                    if vf & 128 != 0 && vf & 64 == 0 {
                        faces.append([v.int(71), v.int(72), v.int(73), v.int(74)].filter { $0 != 0 })
                    } else {
                        positions.append(point(v, 10))
                    }
                }
                return faces.compactMap { face in
                    let pts = face.compactMap { idx -> Point3? in
                        let i = abs(idx) - 1
                        return positions.indices.contains(i) ? positions[i] : nil
                    }
                    return pts.count >= 2 ? .polyline(pts, closed: pts.count > 2, bulges: [], layer: layer) : nil
                }
            }
            if flags & 16 != 0 {
                // Polygon mesh M × N.
                let m = r.int(71), n = r.int(72)
                let pts = vertices.map { point($0, 10) }
                guard m > 1, n > 1, pts.count >= m * n else { return [] }
                var out: [Entity] = []
                for i in 0..<m { out.append(.polyline((0..<n).map { pts[i * n + $0] }, closed: flags & 32 != 0, bulges: [], layer: layer)) }
                for j in 0..<n { out.append(.polyline((0..<m).map { pts[$0 * n + j] }, closed: flags & 1 != 0, bulges: [], layer: layer)) }
                return out
            }
            // Spline-frame control points (flag 16 on the vertex) are not part of the outline.
            let used = vertices.filter { $0.int(70) & 16 == 0 }
            guard used.count >= 2 else { return [] }
            let is3D = flags & 8 != 0
            let pts = used.map { v -> Point3 in
                let p = point(v, 10)
                return is3D ? p : ocs.world(Point3(p.x, p.y, r.double(30)))
            }
            let sign: Double = !is3D && ocs.isFlipped ? -1 : 1
            return [.polyline(pts, closed: flags & 1 == 1, bulges: used.map { $0.double(42) * sign }, layer: layer)]
        }

        func spline(_ r: DXFRecord, layer: String) -> [Entity] {
            var control: [Point3] = [], fit: [Point3] = []
            var knots: [Double] = [], weights: [Double] = []
            var section = 0
            for g in r.groups {
                switch g.code {
                case 10: control.append(Point3(g.double, 0, 0)); section = 10
                case 20 where section == 10 && !control.isEmpty: control[control.count - 1].y = g.double
                case 30 where section == 10 && !control.isEmpty: control[control.count - 1].z = g.double
                case 11: fit.append(Point3(g.double, 0, 0)); section = 11
                case 21 where section == 11 && !fit.isEmpty: fit[fit.count - 1].y = g.double
                case 31 where section == 11 && !fit.isEmpty: fit[fit.count - 1].z = g.double
                case 40: knots.append(g.double)
                case 41: weights.append(g.double)
                default: break
                }
            }
            if control.count < 2 {
                guard fit.count >= 2 else { return [] }
                return [.polyline(fit, closed: r.int(70) & 1 == 1, bulges: [], layer: layer)]
            }
            return [.spline(degree: max(r.int(71, 3), 1), controlPoints: control, knots: knots, weights: weights, layer: layer)]
        }

        func text(_ r: DXFRecord, layer: String) -> [Entity] {
            guard let raw = r.string(1), !raw.isEmpty else { return [] }
            let value = DrawingText.unicodeEscapes(raw)
            let h = r.int(72), v = r.int(73)
            let anchored = (h != 0 || v != 0) && r.has(11)
            let ocs = OCS(r.extrusion)
            var at = point(r, anchored ? 11 : 10)
            at = ocs.world(at)
            var rotation = r.double(50)
            if ocs.isFlipped { rotation = 180 - rotation }
            let align: CADDrawing.TextAlign
            switch (h, v) {
            case (1, 0): align = .baselineCentre
            case (2, 0): align = .baselineRight
            case (4, _): align = .middleCentre
            case (0, 1): align = .bottomLeft
            case (1, 1): align = .bottomCentre
            case (2, 1): align = .bottomRight
            case (0, 2): align = .middleLeft
            case (1, 2): align = .middleCentre
            case (2, 2): align = .middleRight
            case (0, 3): align = .topLeft
            case (1, 3): align = .topCentre
            case (2, 3): align = .topRight
            default: align = .baselineLeft
            }
            return [.text(value, at: at, height: r.double(40, 1), rotation: rotation, style: r.string(7) ?? "STANDARD", align: align,
                          widthFactor: r.double(41, 1) > 0 ? r.double(41, 1) : 1, layer: layer)]
        }

        func mtext(_ r: DXFRecord, layer: String) -> [Entity] {
            // Chunks of 250 characters arrive as group 3 (all but the last) then group 1.
            let value = r.all(3).map(\.text).joined() + (r.string(1) ?? "")
            guard !value.isEmpty else { return [] }
            var rotation = r.double(50)
            if r.has(11) { rotation = atan2(r.double(21), r.double(11)) * 180 / .pi }
            return [.multilineText(value, at: point(r, 10), height: r.double(40, 1), width: r.double(41), rotation: rotation,
                                   attachment: min(max(r.int(71, 1), 1), 9), style: r.string(7) ?? "STANDARD", layer: layer)]
        }

        func leader(_ r: DXFRecord, layer: String) -> [Entity] {
            var pts: [Point3] = []
            for g in r.groups {
                switch g.code {
                case 10: pts.append(Point3(g.double, 0, 0))
                case 20: if !pts.isEmpty { pts[pts.count - 1].y = g.double }
                case 30: if !pts.isEmpty { pts[pts.count - 1].z = g.double }
                default: break
                }
            }
            return pts.count >= 2 ? [.polyline(pts, closed: false, bulges: [], layer: layer)] : []
        }

        /// MLEADER: the leader lines and the text, best effort (the entity's context data is a nested structure).
        func mleader(_ r: DXFRecord, layer: String) -> [Entity] {
            var out: [Entity] = []
            var inLine = false
            var pts: [Point3] = []
            var textValue: String?
            for g in r.groups {
                if g.code == 304 {
                    if g.text == "LEADER_LINE{" { inLine = true; pts = [] }
                    else if textValue == nil { textValue = g.text }
                } else if g.code == 305, inLine {
                    inLine = false
                    if pts.count >= 2 { out.append(.polyline(pts, closed: false, bulges: [], layer: layer)) }
                } else if inLine {
                    switch g.code {
                    case 10: pts.append(Point3(g.double, 0, 0))
                    case 20: if !pts.isEmpty { pts[pts.count - 1].y = g.double }
                    case 30: if !pts.isEmpty { pts[pts.count - 1].z = g.double }
                    default: break
                    }
                }
            }
            if let textValue, !textValue.isEmpty, r.has(12) {
                out.append(.multilineText(textValue, at: point(r, 12), height: r.double(41, 2.5), width: 0, style: "STANDARD", layer: layer))
            }
            return out
        }

        mutating func insert(_ r: DXFRecord, _ attributes: [DXFRecord]) -> [Entity] {
            guard let block = r.string(2) else { return [] }
            let layer = r.string(8) ?? "0"
            let ocs = OCS(r.extrusion)
            var at = point(r, 10)
            var scale = Point3(r.double(41, 1), r.double(42, 1), r.double(43, 1))
            var rotation = r.double(50)
            if !ocs.isIdentity {
                at = ocs.world(at)
                if ocs.isFlipped { scale.x = -scale.x; rotation = -rotation }
            }
            var columns = max(r.int(70, 1), 1), rows = max(r.int(71, 1), 1)
            // A damaged count can ask for billions of copies; the array is cut to `maxArrayCells`, rows first.
            if columns * rows > DXFReader.maxArrayCells {
                noteLoss("array INSERT cells")
                columns = min(columns, DXFReader.maxArrayCells); rows = max(DXFReader.maxArrayCells / columns, 1)
            }
            let dx = r.double(44), dy = r.double(45)
            var out: [Entity] = []
            let a = rotation * .pi / 180
            for row in 0..<rows {
                for col in 0..<columns {
                    // The array spacing is along the block's own axes, so it rotates with the insert.
                    let ox = Double(col) * dx, oy = Double(row) * dy
                    let p = Point3(at.x + ox * cos(a) - oy * sin(a), at.y + ox * sin(a) + oy * cos(a), at.z)
                    out.append(.insert(block: block, at: p, scale: scale, rotation: rotation, layer: layer))
                }
            }
            for attribute in attributes where attribute.int(70) & 1 == 0 {
                if let value = attribute.string(1), !value.isEmpty {
                    out.append(contentsOf: text(attribute, layer: attribute.string(8) ?? layer).map { styled($0, attribute) })
                }
            }
            return out
        }

        // MARK: HATCH

        func hatch(_ r: DXFRecord, layer: String) -> [Entity] {
            let ocs = OCS(r.extrusion)
            let elevation = r.double(30)
            let g = r.groups
            var i = 0
            func peek() -> DXFGroup? { i < g.count ? g[i] : nil }
            // Skip to the boundary path count (91).
            while i < g.count, g[i].code != 91 { i += 1 }
            guard i < g.count else { return [] }
            let pathCount = max(g[i].int, 0); i += 1
            var loops: [[Point3]] = []
            for _ in 0..<pathCount {
                while i < g.count, g[i].code != 92 { i += 1 }
                guard i < g.count else { break }
                let pathType = g[i].int; i += 1
                var loop: [Point3] = []
                if pathType & 2 != 0 {
                    var hasBulge = false, closed = true, count = 0
                    if peek()?.code == 72 { hasBulge = g[i].int != 0; i += 1 }
                    if peek()?.code == 73 { closed = g[i].int != 0; i += 1 }
                    if peek()?.code == 93 { count = g[i].int; i += 1 }
                    var verts: [(x: Double, y: Double, b: Double)] = []
                    while verts.count < count, let c = peek(), c.code == 10 {
                        let x = c.double; i += 1
                        var y = 0.0, b = 0.0
                        if peek()?.code == 20 { y = g[i].double; i += 1 }
                        if hasBulge, peek()?.code == 42 { b = g[i].double; i += 1 }
                        verts.append((x, y, b))
                    }
                    loop = flatten(verts.map { ($0.x, $0.y) }, bulges: verts.map(\.b), closed: closed).map { Point3($0.0, $0.1, elevation) }
                } else {
                    var edgeCount = 0
                    if peek()?.code == 93 { edgeCount = max(g[i].int, 0); i += 1 }
                    var pts: [(Double, Double)] = []
                    for _ in 0..<edgeCount {
                        guard peek()?.code == 72 else { break }
                        let type = g[i].int; i += 1
                        var vals: [Int: [Double]] = [:]
                        // Edge fields run until the next edge (72), the source-object count (97) or the next path (92).
                        while let c = peek(), ![72, 97, 92, 75].contains(c.code) {
                            vals[c.code, default: []].append(c.double); i += 1
                        }
                        pts.append(contentsOf: edgePoints(type, vals))
                    }
                    loop = pts.map { Point3($0.0, $0.1, elevation) }
                }
                if peek()?.code == 97 {
                    var n = g[i].int; i += 1
                    while n > 0, peek()?.code == 330 { i += 1; n -= 1 }
                }
                if loop.count >= 3 { loops.append(loop.map { ocs.world($0) }) }
            }
            // Pattern definition lines (stored final: scale and angle already applied).
            var lines: [CADDrawing.HatchLine] = []
            if let at = g[i...].firstIndex(where: { $0.code == 78 }) {
                var k = at
                let count = max(g[k].int, 0); k += 1
                for _ in 0..<count {
                    guard k < g.count, g[k].code == 53 else { break }
                    let angle = g[k].double; k += 1
                    var base = (0.0, 0.0), offset = (0.0, 0.0)
                    var dashes: [Double] = []
                    while k < g.count {
                        let c = g[k]
                        if c.code == 53 || c.code == 47 || c.code == 98 { break }
                        switch c.code {
                        case 43: base.0 = c.double
                        case 44: base.1 = c.double
                        case 45: offset.0 = c.double
                        case 46: offset.1 = c.double
                        case 49: dashes.append(c.double)
                        default: break
                        }
                        k += 1
                    }
                    lines.append(.init(angle: angle, base: Point3(base.0, base.1, elevation), offset: Point3(offset.0, offset.1, 0), dashes: dashes))
                }
            }
            let solid = r.int(70) == 1 || r.has(450) && r.int(450) != 0
            guard !loops.isEmpty else { return [] }
            return [.hatch(loops: loops, pattern: r.string(2) ?? "SOLID", solid: solid || lines.isEmpty, patternLines: solid ? [] : lines, layer: layer)]
        }

        func edgePoints(_ type: Int, _ v: [Int: [Double]]) -> [(Double, Double)] {
            func one(_ c: Int) -> Double { v[c]?.first ?? 0 }
            switch type {
            case 1:
                return [(one(10), one(20)), (one(11), one(21))]
            case 2:
                let cx = one(10), cy = one(20), radius = one(40)
                let a0 = one(50), a1 = one(51)
                let ccw = (v[73]?.first ?? 1) != 0
                // A clockwise edge runs from its start angle down to its end angle: the counter-clockwise arc, reversed.
                return ccw ? arcPoints(cx, cy, radius, a0, a1) : arcPoints(cx, cy, radius, a1, a0).reversed()
            case 3:
                let cx = one(10), cy = one(20), mx = one(11), my = one(21), ratio = one(40)
                let ccw = (v[73]?.first ?? 1) != 0
                var a0 = one(50).truncatingRemainder(dividingBy: 360) * .pi / 180, a1 = one(51).truncatingRemainder(dividingBy: 360) * .pi / 180
                if !ccw { swap(&a0, &a1) }
                if a1 <= a0 { a1 += 2 * .pi }
                let n = max(8, Int((a1 - a0) / (.pi / 36)))
                let pts = (0...n).map { k -> (Double, Double) in
                    let t = a0 + (a1 - a0) * Double(k) / Double(n)
                    return (cx + mx * cos(t) - my * ratio * sin(t), cy + my * cos(t) + mx * ratio * sin(t))
                }
                return ccw ? pts : pts.reversed()
            case 4:
                // 10/20 interleave per control point, so the two lists pair up by index.
                let xs = v[10] ?? [], ys = v[20] ?? []
                let controls = zip(xs, ys).map { Point3($0, $1) }
                guard controls.count >= 2 else { return [] }
                let degree = DXFGroup.integer(one(94))
                let knots = (v[40] ?? [])
                let sampled = NURBS.sample(degree: max(degree, 1), controls: controls, knots: knots, weights: [], samples: max(controls.count * 8, 24))
                return sampled.map { ($0.x, $0.y) }
            default: return []
            }
        }

        func arcPoints(_ cx: Double, _ cy: Double, _ r: Double, _ start: Double, _ a1: Double) -> [(Double, Double)] {
            // Angles reduced to one turn, so the sweep is at most 360° whatever the file says.
            let a0 = start.truncatingRemainder(dividingBy: 360)
            var end = a1.truncatingRemainder(dividingBy: 360)
            while end <= a0 { end += 360 }
            let n = max(4, Int((end - a0) / 5))
            return (0...n).map { k in
                let a = (a0 + (end - a0) * Double(k) / Double(n)) * .pi / 180
                return (cx + r * cos(a), cy + r * sin(a))
            }
        }

        /// A bulged polyline flattened to points.
        func flatten(_ pts: [(Double, Double)], bulges: [Double], closed: Bool) -> [(Double, Double)] {
            guard pts.count >= 2 else { return pts }
            var out: [(Double, Double)] = []
            let count = closed ? pts.count : pts.count - 1
            for i in 0..<count {
                let p = pts[i], q = pts[(i + 1) % pts.count]
                out.append(p)
                let b = bulges.indices.contains(i) ? bulges[i] : 0
                if abs(b) > 1e-9 { out.append(contentsOf: BulgeArc(from: p, to: q, bulge: b).interior(step: .pi / 36)) }
            }
            if !closed { out.append(pts[pts.count - 1]) }
            return out
        }

        // MARK: Finish

        mutating func finish() -> DXFReadResult {
            var notes: [LossNote] = []
            if !loss.isEmpty {
                let detail = loss.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
                notes.append(LossNote(.otherLoss, detail: "Not drawn: \(detail)"))
            }
            if drawing.layers.isEmpty { drawing.layers = [.init(name: "0")] }
            for name in blockOrder where !isPaperBlock(name) && !name.lowercased().hasPrefix("*model_space") {
                drawing.blocks.append(.init(name: name, base: blockBases[name] ?? Point3(0, 0), entities: blockEntities[name] ?? []))
            }
            // Layouts: the LAYOUT objects (R2000+) name them and point at their block; entities written to the ENTITIES section
            // with group 67 belong to the layout named by group 410, else to the one using *Paper_Space.
            var names = layoutNames
            if names.isEmpty && (!paperEntities.isEmpty || blockOrder.contains(where: isPaperBlock)) { names = ["Layout1"] }
            for name in names {
                var entities: [Entity] = []
                if let handle = layoutBlockHandle[name], let block = blockRecordName[handle] { entities += blockEntities[block] ?? [] }
                let activeName = names.first { layoutBlockHandle[$0].flatMap { blockRecordName[$0] }?.lowercased() == "*paper_space" } ?? names.first
                entities += paperEntities.filter { ($0.layout ?? activeName) == name }.map(\.entity)
                if layoutBlockHandle.isEmpty, names.count == 1 {
                    for block in blockOrder where isPaperBlock(block) { entities += blockEntities[block] ?? [] }
                }
                drawing.layouts.append(.init(name: name, paperSize: layoutPaper[name], entities: entities))
            }
            return DXFReadResult(drawing: drawing, lossNotes: notes)
        }

        func isPaperBlock(_ name: String) -> Bool { name.lowercased().hasPrefix("*paper_space") }
    }
}
