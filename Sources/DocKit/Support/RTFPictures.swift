import Foundation

/// Pictures in RTF. AppKit's RTF writer drops attachments and its reader ignores `\pict` groups, so the pictures travel as
/// marker text through TextKit and are swapped for (or out of) `\pict` groups around it. PNG and JPEG only, which is what
/// Word, Pages and TextEdit write and read.
enum RTFPictures {
    static func marker(_ index: Int) -> String { "@@dockit-img-\(index)@@" }
    static let markerPattern = try! NSRegularExpression(pattern: "@@dockit-img-(\\d+)@@")

    /// The RTF with each `\pict` PNG/JPEG group replaced by its marker, and the pictures in marker order.
    static func extract(_ rtf: Data) -> (rtf: Data, pictures: [Data]) {
        let text = String(decoding: rtf, as: UTF8.self)
        guard text.contains("\\pict") else { return (rtf, []) }
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var pictures: [Data] = []
        var i = 0
        func hasPrefix(_ s: String, at index: Int) -> Bool {
            let t = Array(s.unicodeScalars)
            return index + t.count <= chars.count && Array(chars[index..<index + t.count]) == t
        }
        while i < chars.count {
            guard chars[i] == "{", hasPrefix("{\\pict", at: i) else { out.append(chars[i]); i += 1; continue }
            // The group, braces balanced.
            var depth = 0
            var j = i
            while j < chars.count {
                if chars[j] == "\\", j + 1 < chars.count { j += 2; continue }
                if chars[j] == "{" { depth += 1 } else if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            let group = String(String.UnicodeScalarView(chars[i..<min(j + 1, chars.count)]))
            if group.contains("\\pngblip") || group.contains("\\jpegblip") {
                // Drop control words and whitespace; what is left is the hex data.
                let hex = group.replacingOccurrences(of: "\\\\[A-Za-z]+-?[0-9]* ?", with: "", options: .regularExpression)
                    .filter { $0.isHexDigit }
                var data = Data()
                var index = hex.startIndex
                while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), let byte = UInt8(hex[index..<next], radix: 16) {
                    data.append(byte); index = next
                }
                if !data.isEmpty {
                    pictures.append(data)
                    out.append(contentsOf: marker(pictures.count - 1).unicodeScalars)
                    i = j + 1
                    continue
                }
            }
            out.append(contentsOf: group.unicodeScalars)
            i = j + 1
        }
        return (Data(String(out).utf8), pictures)
    }

    /// An RTF `\pict` group for a PNG or JPEG, sized in points.
    static func group(_ data: Data, width: Double, height: Double) -> String {
        let kind = ImageSniff.commonType(data) == "jpeg" ? "jpegblip" : "pngblip"
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return "{\\pict\\\(kind)\\picwgoal\(Int(measure: width * 20))\\pichgoal\(Int(measure: height * 20)) \(hex)}"
    }
}
