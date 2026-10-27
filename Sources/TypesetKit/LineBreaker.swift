import Foundation

/// An item of TeX's horizontal list as the line breaker sees it (Knuth & Plass, "Breaking paragraphs into lines").
struct BreakItem {
    enum Kind { case box, glue, penalty }

    var kind: Kind
    var width: Double
    var stretch: Double = 0
    var shrink: Double = 0
    /// 0 finite, 1 fil.
    var stretchOrder: Int = 0
    var penalty: Int = 0
    /// A hyphen (or other discretionary) break: counts for `\doublehyphendemerits`.
    var flagged = false
    /// Width added at the start of the next line when the paragraph breaks here (the second half of a broken word
    /// shaped on its own, minus its width inside the word).
    var postWidth: Double = 0
    /// How far the first and last characters may hang into the margins (microtype protrusion), for boxes; for a
    /// hyphenation break, `rightProtrusion` is the hyphen's.
    var leftProtrusion: Double = 0
    var rightProtrusion: Double = 0
    /// Index of what the item stands for in the paragraph's fragments (boxes), or -1.
    var fragment: Int = -1
    /// For a hyphenation break: the hyphen to draw (nil for breaks after an explicit hyphen or in URLs).
    var hyphenText: String? = nil
    /// Only offered in the last-resort pass (breaks inside long words and URLs).
    var lastResort = false
    /// Only offered once hyphenation is on (TeX's second pass).
    var isHyphenation = false

    static func box(_ width: Double, fragment: Int, left: Double = 0, right: Double = 0) -> BreakItem {
        BreakItem(kind: .box, width: width, leftProtrusion: left, rightProtrusion: right, fragment: fragment)
    }
    static func glue(_ g: Glue) -> BreakItem {
        BreakItem(kind: .glue, width: g.width, stretch: g.stretch, shrink: g.shrink, stretchOrder: g.stretchOrder)
    }
    static func penalty(_ p: Int, width: Double = 0, flagged: Bool = false) -> BreakItem {
        BreakItem(kind: .penalty, width: width, penalty: p, flagged: flagged)
    }
}

/// TeX's line-breaking parameters (quality §3.3).
struct BreakParameters {
    var pretolerance = 100
    var tolerance = 200
    var linePenalty = 10
    var adjDemerits = 10000
    var doubleHyphenDemerits = 10000
    var finalHyphenDemerits = 5000
    var emergencyStretch = 30.0
    var hyphenate = true
    /// Width of line `n` (0-based).
    var lineWidth: (Int) -> Double
    /// How many leading lines have their own width (2 for a hanging indent after the first line); lines from this
    /// index on are interchangeable, which lets the breaker merge their active nodes.
    var distinctLines = 0
}

/// One chosen breakpoint.
struct LineBreak {
    var position: Int        // index of the break item; items.count - 1 for the paragraph's end
    var filStretch: Bool     // the line's fil glue takes the slack
    var badness: Int
}

struct BreakResult {
    var breaks: [LineBreak]
    /// 1 = no hyphenation needed, 2 = with hyphenation, 3 = emergency stretch, 4 = last resort (breaks in words).
    var pass: Int
}

/// Knuth–Plass optimal line breaking: TeX's algorithm (tex.web §813–§890) with its passes — `\pretolerance` without
/// hyphenation, `\tolerance` with it, then `\emergencystretch`, then a last resort that breaks inside long words — so a
/// line is never overfull while there is any way to avoid it.
enum LineBreaker {
    static let infBad = 10000

    /// TeX's `badness(t, s)`: about 100 (t/s)³, capped at 10000, computed in scaled points as TeX does.
    static func badness(_ t: Double, _ s: Double) -> Int {
        let ti = Int((t * 65536).rounded()), si = Int((s * 65536).rounded())
        if ti == 0 { return 0 }
        if si <= 0 { return infBad }
        var r: Int
        if ti <= 7_230_584 { r = (ti * 297) / si } else if si >= 1_663_497 { r = ti / (si / 297) } else { r = ti }
        if r > 1290 { return infBad }
        return (r * r * r + 0x20000) / 0x40000
    }

    static func breakLines(_ items: [BreakItem], _ params: BreakParameters) -> BreakResult {
        let passes: [(threshold: Int, hyphenate: Bool, emergency: Double, lastResort: Bool)] = [
            (params.pretolerance, false, 0, false),
            (params.tolerance, params.hyphenate, 0, false),
            (params.tolerance, params.hyphenate, params.emergencyStretch, false),
            (infBad, params.hyphenate, params.emergencyStretch, true),
        ]
        for (k, pass) in passes.enumerated() where !(k == 0 && params.pretolerance < 0) {
            if let r = run(items, params, threshold: pass.threshold, hyphenate: pass.hyphenate, emergency: pass.emergency,
                           lastResort: pass.lastResort) {
                return BreakResult(breaks: r, pass: k + 1)
            }
        }
        // Nothing fits even with breaks inside words (a single glyph wider than the measure): break at every chance.
        var breaks: [LineBreak] = []
        for (i, item) in items.enumerated() where i < items.count - 1 {
            let legal = (item.kind == .penalty && item.penalty < 10000) || (item.kind == .glue && i > 0 && items[i - 1].kind == .box)
            if legal { breaks.append(LineBreak(position: i, filStretch: false, badness: infBad)) }
        }
        breaks.append(LineBreak(position: items.count - 1, filStretch: false, badness: infBad))
        return BreakResult(breaks: breaks, pass: 4)
    }

    /// First fit, for ragged and centred text (LaTeX's `\raggedright` and `\centering` give every line badness 0, so
    /// each line simply takes the words that fit): a word wider than the measure breaks at its last-resort points.
    static func firstFit(_ items: [BreakItem], lineWidth: (Int) -> Double) -> BreakResult {
        let n = items.count
        var breaks: [LineBreak] = []
        var lineStart = 0
        var width = 0.0
        var lastFit: Int? = nil, lastResortFit: Int? = nil
        var usedLastResort = false
        var i = 0
        func legal(_ k: Int) -> Bool {
            let it = items[k]
            switch it.kind {
            case .penalty: return it.penalty < 10000 && !it.isHyphenation
            case .glue: return k > 0 && items[k - 1].kind == .box
            case .box: return false
            }
        }
        func restart(after b: Int) {
            var j = b + 1
            while j < n, items[j].kind != .box, !(items[j].kind == .penalty && items[j].penalty <= -10000) { j += 1 }
            lineStart = j; i = j
            width = items[b].kind == .penalty ? items[b].postWidth : 0
            lastFit = nil; lastResortFit = nil
        }
        while i < n {
            let it = items[i]
            let limit = lineWidth(breaks.count)
            if it.kind == .penalty && it.penalty <= -10000 {
                breaks.append(LineBreak(position: i, filStretch: true, badness: 0))
                if i == n - 1 { break }
                restart(after: i)
                continue
            }
            if legal(i) && width + (it.kind == .penalty ? it.width : 0) <= limit + 1e-6 {
                if it.lastResort { lastResortFit = i } else { lastFit = i }
            }
            if it.kind != .penalty { width += it.width }
            if width > limit + 1e-6 && it.kind == .box, let b = lastFit ?? lastResortFit, b >= lineStart {
                if lastFit == nil { usedLastResort = true }
                breaks.append(LineBreak(position: b, filStretch: true, badness: 0))
                restart(after: b)
                continue
            }
            i += 1
        }
        if breaks.last?.position != n - 1 { breaks.append(LineBreak(position: n - 1, filStretch: true, badness: 0)) }
        return BreakResult(breaks: breaks, pass: usedLastResort ? 4 : 1)
    }

    private struct Active {
        var position: Int
        var line: Int
        var fitness: Int
        var totalWidth: Double, totalStretch: Double, totalShrink: Double, totalFil: Double
        var demerits: Double
        var node: Int
        var flagged: Bool
        /// Hyphenated lines in a row ending here: a third is not allowed (the lint's "at most two").
        var hyphenRun: Int
        var postWidth: Double
        var leftProtrusion: Double
    }

    private struct Node {
        var position: Int
        var previous: Int
        var fil: Bool
        var badness: Int
    }

    private static func run(_ items: [BreakItem], _ params: BreakParameters, threshold: Int, hyphenate: Bool,
                            emergency: Double, lastResort: Bool) -> [LineBreak]? {
        let n = items.count
        guard n > 0 else { return [] }
        // Running sums before item i.
        var sumW = [Double](repeating: 0, count: n + 1)
        var sumY = sumW, sumZ = sumW, sumF = sumW
        for i in 0..<n {
            let it = items[i]
            sumW[i + 1] = sumW[i]; sumY[i + 1] = sumY[i]; sumZ[i + 1] = sumZ[i]; sumF[i + 1] = sumF[i]
            switch it.kind {
            case .box: sumW[i + 1] += it.width
            case .glue:
                sumW[i + 1] += it.width
                if it.stretchOrder > 0 { sumF[i + 1] += it.stretch } else { sumY[i + 1] += it.stretch }
                sumZ[i + 1] += it.shrink
            case .penalty: break
            }
        }
        func isLegal(_ i: Int) -> Bool {
            let it = items[i]
            switch it.kind {
            case .penalty: return it.penalty < 10000 && (!it.lastResort || lastResort) && (!it.isHyphenation || hyphenate)
            case .glue: return i > 0 && items[i - 1].kind == .box
            case .box: return false
            }
        }
        /// Totals after a break at `b`: glue and penalties after a break are discarded up to the next box.
        func afterBreak(_ b: Int) -> (Double, Double, Double, Double) {
            var j = b + 1
            if b >= 0 {
                while j < n, items[j].kind != .box, !(items[j].kind == .penalty && items[j].penalty <= -10000) { j += 1 }
            }
            return (sumW[j], sumY[j], sumZ[j], sumF[j])
        }
        func firstBoxProtrusion(after b: Int) -> Double {
            var j = b + 1
            while j < n, items[j].kind != .box { if items[j].kind == .penalty && items[j].penalty <= -10000 { return 0 }; j += 1 }
            return j < n ? items[j].leftProtrusion : 0
        }
        func lastBoxProtrusion(before b: Int) -> Double {
            if items[b].kind == .penalty && items[b].hyphenText != nil { return items[b].rightProtrusion }
            var j = b - 1
            while j >= 0, items[j].kind != .box { if items[j].kind == .glue { return 0 }; j -= 1 }
            return j >= 0 ? items[j].rightProtrusion : 0
        }

        var nodes = [Node(position: -1, previous: -1, fil: false, badness: 0)]
        let start = afterBreak(-1)
        // TeX's initial active node is `decent_fit`.
        var active = [Active(position: -1, line: 0, fitness: 2, totalWidth: start.0, totalStretch: start.1, totalShrink: start.2,
                             totalFil: start.3, demerits: 0, node: 0, flagged: false, hyphenRun: 0, postWidth: 0,
                             leftProtrusion: firstBoxProtrusion(after: -1))]

        for b in 0..<n where isLegal(b) {
            let item = items[b]
            let pi = item.kind == .penalty ? item.penalty : 0
            let breakWidth = item.kind == .penalty ? item.width : 0
            let rightProt = lastBoxProtrusion(before: b)
            let isFinal = b == n - 1
            var best: [Int: (demerits: Double, from: Int, fil: Bool, badness: Int, line: Int, run: Int)] = [:]
            var survivors: [Active] = []
            for a in active {
                let width = sumW[b] - a.totalWidth + breakWidth + a.postWidth
                let stretch = sumY[b] - a.totalStretch + emergency
                let fil = sumF[b] - a.totalFil
                let shrink = sumZ[b] - a.totalShrink
                let shortfall = params.lineWidth(a.line) + a.leftProtrusion + rightProt - width
                var bad: Int, fitness: Int
                var filLine = false
                var deactivate = pi <= -10000
                if shortfall > 0 {
                    if fil > 0 { bad = 0; fitness = 2; filLine = true }
                    else {
                        bad = badness(shortfall, stretch)
                        fitness = bad > 12 ? (bad > 99 ? 0 : 1) : 2
                    }
                } else if shortfall < 0 {
                    if -shortfall > shrink + 1e-9 { bad = infBad + 1; deactivate = true; fitness = 3 }
                    else {
                        bad = badness(-shortfall, shrink)
                        fitness = bad > 12 ? 3 : 2
                    }
                } else { bad = 0; fitness = 2 }
                if !deactivate { survivors.append(a) }
                if bad > threshold { continue }
                let run = item.flagged && !isFinal ? a.hyphenRun + 1 : 0
                if run > 2 && !lastResort { continue }
                var d = Double(params.linePenalty + bad)
                d = abs(d) >= 10000 ? 100_000_000 : d * d
                if pi > 0 { d += Double(pi * pi) } else if pi > -10000 { d -= Double(pi * pi) }
                // The paragraph's end counts as a hyphenated break (tex.web §859): a hyphen on the last-but-one line
                // costs `\finalhyphendemerits`.
                if a.flagged && (item.flagged || isFinal) {
                    d += Double(isFinal ? params.finalHyphenDemerits : params.doubleHyphenDemerits)
                }
                if abs(fitness - a.fitness) > 1 { d += Double(params.adjDemerits) }
                d += a.demerits
                let lineClass = params.distinctLines > 0 ? min(a.line + 1, params.distinctLines) : 0
                let key = fitness * 1000 + lineClass * 10 + min(run, 2)
                if best[key] == nil || d < best[key]!.demerits {
                    best[key] = (d, a.node, filLine, bad, a.line + 1, run)
                }
            }
            active = survivors
            if !best.isEmpty {
                let after = afterBreak(b)
                let minimum = best.values.map(\.demerits).min()!
                for (key, c) in best.sorted(by: { $0.key < $1.key }) where c.demerits <= minimum + Double(params.adjDemerits) {
                    nodes.append(Node(position: b, previous: c.from, fil: c.fil, badness: c.badness))
                    active.append(Active(position: b, line: c.line, fitness: key / 1000, totalWidth: after.0,
                                         totalStretch: after.1, totalShrink: after.2, totalFil: after.3, demerits: c.demerits,
                                         node: nodes.count - 1, flagged: item.flagged, hyphenRun: c.run,
                                         postWidth: item.kind == .penalty ? item.postWidth : 0,
                                         leftProtrusion: firstBoxProtrusion(after: b)))
                }
            }
            if active.isEmpty { return nil }
        }
        guard let final = active.filter({ $0.position == n - 1 }).min(by: { $0.demerits < $1.demerits }) else { return nil }
        var result: [LineBreak] = []
        var idx = final.node
        while idx > 0 {
            let node = nodes[idx]
            result.append(LineBreak(position: node.position, filStretch: node.fil, badness: node.badness))
            idx = node.previous
        }
        return result.reversed()
    }
}
