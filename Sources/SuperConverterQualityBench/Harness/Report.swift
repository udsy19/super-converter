import Foundation

/// The run's JSON (for CI and the catalog test) and the HTML gallery for human review (quality §9).
struct Report: Codable {
    var tier: Tier
    var date: Date
    var validation: [ValidationEntry]
    var cases: [CaseResult]

    struct ValidationEntry: Codable { var name: String; var passed: Bool; var skipped: Bool; var detail: String }

    var failures: [CaseResult] { cases.filter { $0.status == .failed || $0.status == .regressed } }
    var count: [Status: Int] { Dictionary(grouping: cases, by: \.status).mapValues(\.count) }

    /// Ids of the cases that passed — what the catalog test reads to decide a pair may be marked shipped.
    var passedIDs: [String] { cases.filter { $0.status == .passed }.map(\.id) }

    @discardableResult
    func write(to folder: URL = RepoRoot.quality) -> (json: URL, html: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = folder.appendingPathComponent("report.json"), html = folder.appendingPathComponent("index.html")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(self).write(to: json)
        try? Data(htmlPage(relativeTo: folder).utf8).write(to: html)
        return (json, html)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    func htmlPage(relativeTo folder: URL) -> String {
        let e = Self.escape
        let base = folder.standardizedFileURL.path + "/"
        func relative(_ path: String) -> String { path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path }
        var body = ""
        let c = count
        body += "<p class=\"sum\">\(cases.count) cases · \(c[.passed] ?? 0) passed · \(c[.failed] ?? 0) failed · \(c[.regressed] ?? 0) regressed · \(c[.skipped] ?? 0) skipped</p>"
        body += "<h2>Metric self-validation</h2><table>" + validation.map {
            "<tr class=\"\($0.skipped ? "skipped" : $0.passed ? "passed" : "failed")\"><td>\($0.skipped ? "skip" : $0.passed ? "ok" : "FAIL")</td><td>\(e($0.name))</td><td>\(e($0.detail))</td></tr>"
        }.joined() + "</table>"
        for category in Category.allCases {
            let rows = cases.filter { $0.category == category }
            if rows.isEmpty { continue }
            body += "<h2>\(category.rawValue)</h2>"
            for r in rows {
                body += "<section class=\"case \(r.status.rawValue)\"><h3>\(e(r.id)) <span class=\"badge\">\(r.status.rawValue)</span> <small>\(r.tier.rawValue) · \(String(format: "%.1f", r.seconds)) s · \(r.inputBytes) → \(r.outputBytes) bytes</small></h3>"
                if !r.message.isEmpty { body += "<p class=\"msg\">\(e(r.message))</p>" }
                if !r.measurements.isEmpty {
                    body += "<table>" + r.measurements.map {
                        "<tr class=\"\($0.passes ? "" : "failed")\"><td>\(e($0.name))</td><td>\(Measurement.format($0.value)) \(e($0.unit))</td><td>\(e($0.limit?.text ?? ""))</td></tr>"
                    }.joined() + "</table>"
                }
                if !r.lossNotes.isEmpty { body += "<p class=\"notes\">Loss notes: \(e(r.lossNotes.joined(separator: "; ")))</p>" }
                if !r.artifacts.isEmpty {
                    body += "<div class=\"art\">" + r.artifacts.map { "<figure><img src=\"\(e(relative($0.path)))\" alt=\"\(e($0.label))\"><figcaption>\(e($0.label))</figcaption></figure>" }.joined() + "</div>"
                }
                body += "</section>"
            }
        }
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Super Converter quality bench</title><style>
        :root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--mut:#6e6e73;--ok:#1b7f3b;--bad:#c4281c;--skip:#8a6d00;--line:#d2d2d7}
        @media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f5f5f7;--mut:#98989d;--ok:#4cd964;--bad:#ff6b5e;--skip:#e0b84a;--line:#3a3a3c}}
        body{background:var(--bg);color:var(--fg);font:14px -apple-system,system-ui,sans-serif;margin:0 auto;max-width:980px;padding:24px 16px}
        h1{font-size:22px}h2{font-size:17px;margin-top:32px;text-transform:capitalize}h3{font-size:14px;margin:0 0 6px}small{color:var(--mut);font-weight:400}
        table{border-collapse:collapse;width:100%;font-size:13px}td{border-top:1px solid var(--line);padding:3px 8px;vertical-align:top}
        .case{border:1px solid var(--line);border-left-width:4px;border-radius:6px;padding:10px 12px;margin:10px 0}
        .passed{border-left-color:var(--ok)}.failed,.regressed{border-left-color:var(--bad)}.skipped{border-left-color:var(--skip)}
        tr.failed td{color:var(--bad)}.badge{font-size:11px;text-transform:uppercase;color:var(--mut)}.msg{color:var(--bad);margin:4px 0}.notes,.sum{color:var(--mut)}
        .art{display:flex;flex-wrap:wrap;gap:12px;margin-top:8px}figure{margin:0}img{max-width:300px;max-height:300px;border:1px solid var(--line);image-rendering:auto}figcaption{font-size:12px;color:var(--mut)}
        </style></head><body><h1>Super Converter quality bench</h1><p class="sum">tier \(tier.rawValue) · \(ISO8601DateFormatter().string(from: date))</p>\(body)</body></html>
        """
    }
}
