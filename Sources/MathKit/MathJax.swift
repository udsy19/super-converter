import CoreText
import Foundation
import JavaScriptCore
import SuperConverterCore

/// A formula set by MathJax, in points at the size asked for: x runs right from the left edge, y up from the baseline.
public struct MathRendering: Sendable {
    public var width: Double
    public var height: Double
    public var depth: Double
    /// MathJax's SVG as vector nodes: Computer Modern outlines as filled paths, rules, and the odd character its fonts
    /// lack as text.
    public var nodes: [VectorNode]
    /// Undefined macros (set in red, as MathJax's noundefined does) and parse errors (the source set in red).
    public var problems: [String]
    /// The equation number from `\tag{…}`, as printed: "(3)", or the text of `\tag*{…}`.
    public var tag: String?
}

/// TeX math through MathJax 3 in JavaScriptCore (quality §3.4): TeX input jax, SVG output jax, lite DOM adaptor — no
/// browser and no network. The script is `Resources/MathJax/mathjax-tex-svg.js`; one context serves every formula,
/// behind a lock (a JSContext is not thread-safe).
public final class MathJax: @unchecked Sendable {
    private let context: JSContext
    private let convert: JSValue
    private let lock = NSLock()

    public init(script url: URL) throws {
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let context = JSContext() else { throw MathJaxError.noContext }
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(source, withSourceURL: url)
        guard exception == nil, let convert = context.objectForKeyedSubscript("superConverterTeX"), !convert.isUndefined else {
            throw MathJaxError.script(exception ?? "superConverterTeX is missing")
        }
        self.context = context
        self.convert = convert
    }

    /// The script shipped with the app: `Contents/Resources/MathJax` in the bundle, else the repository's
    /// `Resources/MathJax` when running from a SwiftPM build (self-test, `sconv`, the bench).
    public static func bundledScript() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("MathJax/mathjax-tex-svg.js")) }
        var source = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { source.deleteLastPathComponent() }   // <root>/Sources/MathKit/MathJax.swift → <root>
        candidates.append(source.appendingPathComponent("Resources/MathJax/mathjax-tex-svg.js"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// One MathJax for the process, loaded on first use (evaluating the script takes a few hundred milliseconds).
    public static let shared: Result<MathJax, MathJaxError> = {
        guard let url = bundledScript() else { return .failure(.script("Resources/MathJax/mathjax-tex-svg.js is missing")) }
        do { return .success(try MathJax(script: url)) }
        catch let error as MathJaxError { return .failure(error) }
        catch { return .failure(.script(error.localizedDescription)) }
    }()

    /// Sets `tex` in display or text style at `size` points.
    public func typeset(_ tex: String, display: Bool, size: Double) -> MathRendering {
        let (body, tag) = Self.splitTag(tex)
        let source = display ? Self.wrapRows(body) : body
        lock.lock()
        let json = convert.call(withArguments: [source, display])?.toString()
        lock.unlock()
        guard let data = json?.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorRendering(tex, size: size, problem: "MathJax failed")
        }
        let errors = result["errors"] as? [String] ?? []
        if let first = errors.first { return errorRendering(body, size: size, problem: first) }
        let em = size
        var nodes: [VectorNode] = []
        for item in result["nodes"] as? [[Any]] ?? [] {
            guard let kind = item.first as? Int else { continue }
            switch kind {
            case 0:
                let segments = Self.segments(item[2], em)
                nodes.append(.path(segments, fill: .solid(Self.colour(item[1] as? String)), stroke: nil))
            case 2:
                let width = (item[2] as? Double ?? 0) * em
                let paint = VectorPaint.solid(Self.colour(item[1] as? String))
                nodes.append(.path(Self.segments(item[3], em), fill: nil, stroke: VectorStroke(paint: paint, width: width)))
            case 1:
                let variant = item[6] as? String ?? "normal", mono = item[7] as? Bool ?? false
                let bold = variant.contains("bold"), italic = variant.contains("italic")
                let font = mono ? "Menlo-Regular" : bold && italic ? "Times-BoldItalic" : bold ? "Times-Bold" : italic ? "Times-Italic" : "Times-Roman"
                nodes.append(.text(VectorTextRun(text: item[2] as? String ?? "", fontName: font, size: (item[5] as? Double ?? 1) * em,
                                                 origin: VectorPoint((item[3] as? Double ?? 0) * em, (item[4] as? Double ?? 0) * em),
                                                 fill: .solid(Self.colour(item[1] as? String)))))
            default: break
            }
        }
        return MathRendering(width: (result["w"] as? Double ?? 0) * em, height: (result["h"] as? Double ?? 0) * em,
                             depth: (result["d"] as? Double ?? 0) * em, nodes: nodes,
                             problems: result["undefined"] as? [String] ?? [], tag: tag)
    }

    /// A formula MathJax cannot parse: its source in red monospace, as TeX's error recovery would leave it visible.
    private func errorRendering(_ tex: String, size: Double, problem: String) -> MathRendering {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, CGFloat(size * 0.9), nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: tex, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let red = VectorColour(red: 0.8, green: 0, blue: 0)
        let run = VectorTextRun(text: tex, fontName: "Menlo-Regular", size: size * 0.9, origin: VectorPoint(0, 0), fill: .solid(red))
        return MathRendering(width: width, height: Double(ascent), depth: Double(descent), nodes: [.text(run)],
                             problems: ["\(problem) in “\(tex)”"], tag: nil)
    }

    // MARK: Source preparation

    /// Takes `\tag{…}`/`\tag*{…}` out of the formula (TypesetKit sets the number at the margin, as LaTeX does) and drops
    /// `\label{…}`, `\nonumber` and `\notag`.
    static func splitTag(_ tex: String) -> (String, String?) {
        var out = "", tag: String?
        let chars = Array(tex)
        var i = 0
        func argument(from start: Int) -> (String, Int)? {
            var j = start
            while j < chars.count, chars[j] == " " { j += 1 }
            guard j < chars.count, chars[j] == "{" else { return nil }
            var depth = 0, k = j
            while k < chars.count {
                if chars[k] == "\\" { k += 2; continue }
                if chars[k] == "{" { depth += 1 } else if chars[k] == "}" { depth -= 1; if depth == 0 { break } }
                k += 1
            }
            guard k < chars.count else { return nil }
            return (String(chars[(j + 1)..<k]), k + 1)
        }
        while i < chars.count {
            if chars[i] == "\\" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter { j += 1 }
                let name = String(chars[(i + 1)..<j])
                let starred = j < chars.count && chars[j] == "*"
                switch name {
                case "tag":
                    if let (text, next) = argument(from: starred ? j + 1 : j) { tag = starred ? text : "(\(text))"; i = next; continue }
                case "label":
                    if let (_, next) = argument(from: j) { i = next; continue }
                case "nonumber", "notag":
                    i = j; continue
                default:
                    if j == i + 1, j < chars.count { out.append(chars[i]); out.append(chars[j]); i = j + 1; continue }
                }
                out += String(chars[i..<j]); i = j
                continue
            }
            out.append(chars[i]); i += 1
        }
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), tag)
    }

    /// Display math with rows (`\\`) outside any environment, as Markdown's `$$ a &= b \\ c &= d $$` writes an
    /// `align*`: MathJax sets rows only inside an environment, so these are wrapped in `aligned` (or `gathered`).
    static func wrapRows(_ tex: String) -> String {
        var depth = 0, rows = false, columns = false
        let chars = Array(tex)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                if chars[i + 1] == "\\" { if depth == 0 { rows = true }; i += 2; continue }
                let name = String(chars[(i + 1)..<min(chars.count, i + 7)])
                if name.hasPrefix("begin{") { depth += 1 } else if name.hasPrefix("end{") { depth -= 1 }
                i += 2; continue
            }
            if chars[i] == "&", depth == 0 { columns = true }
            i += 1
        }
        guard rows || columns else { return tex }
        let env = columns ? "aligned" : "gathered"
        return "\\begin{\(env)}\(tex)\\end{\(env)}"
    }

    // MARK: Results

    /// Reads the parsed JSON's arrays and numbers in place: bridging them to `[[Double]]` first copied every number, which
    /// was most of the Swift side's time per formula.
    private static func segments(_ value: Any, _ em: Double) -> [PathSegment] {
        guard let list = value as? NSArray else { return [] }
        var out: [PathSegment] = []
        out.reserveCapacity(list.count)
        for case let s as NSArray in list {
            let n = s.count
            func p(_ i: Int) -> VectorPoint {
                VectorPoint(((s[i] as? NSNumber)?.doubleValue ?? 0) * em, ((s[i + 1] as? NSNumber)?.doubleValue ?? 0) * em)
            }
            switch n > 0 ? (s[0] as? NSNumber)?.intValue ?? -1 : -1 {
            case 0 where n >= 3: out.append(.move(p(1)))
            case 1 where n >= 3: out.append(.line(p(1)))
            case 2 where n >= 7: out.append(.cubic(p(1), p(3), p(5)))
            case 3: out.append(.close)
            default: break
            }
        }
        return out
    }

    /// SVG colours as MathJax writes them for `\color`: `#rgb`, `#rrggbb`, `rgb(…)` or a CSS name; none is black.
    static func colour(_ css: String?) -> VectorColour {
        guard var s = css?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return VectorColour(red: 0, green: 0, blue: 0) }
        if let named = cssNames[s] { s = named }
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6, let v = Int(hex, radix: 16) {
                return VectorColour(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
            }
        }
        if s.hasPrefix("rgb") {
            let parts = s.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let v = parts.prefix(3).map { $0.hasSuffix("%") ? (Double($0.dropLast()) ?? 0) / 100 : (Double($0) ?? 0) / 255 }
            if v.count == 3 { return VectorColour(red: v[0], green: v[1], blue: v[2]) }
        }
        return VectorColour(red: 0, green: 0, blue: 0)
    }

    private static let cssNames: [String: String] = [
        "black": "#000000", "white": "#ffffff", "red": "#ff0000", "green": "#008000", "blue": "#0000ff", "yellow": "#ffff00",
        "cyan": "#00ffff", "magenta": "#ff00ff", "gray": "#808080", "grey": "#808080", "orange": "#ffa500",
        "purple": "#800080", "brown": "#a52a2a", "lime": "#00ff00", "olive": "#808000", "navy": "#000080",
        "teal": "#008080", "maroon": "#800000", "silver": "#c0c0c0", "pink": "#ffc0cb", "violet": "#ee82ee",
        "darkgray": "#a9a9a9", "lightgray": "#d3d3d3",
    ]
}

public enum MathJaxError: Error, CustomStringConvertible, Sendable {
    case noContext
    case script(String)

    public var description: String {
        switch self {
        case .noContext: "JavaScriptCore could not start"
        case .script(let message): "MathJax did not load: \(message)"
        }
    }
}
