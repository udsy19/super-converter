import Foundation

/// The "Pages" option (formats §5): a range such as "1-3,5" (one-based), empty for all pages.
public enum PageSelection {
    /// Zero-based page indices in the order written, without repeats, clamped to `pageCount`. Empty text selects every page;
    /// text that selects nothing yields an empty list. Open ranges ("4-", "-3") are accepted.
    public static func indices(_ text: String?, pageCount: Int) -> [Int] {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespaces)
        guard pageCount > 0 else { return [] }
        guard !trimmed.isEmpty else { return Array(0..<pageCount) }
        var seen = Set<Int>(), result: [Int] = []
        for part in trimmed.split(whereSeparator: { ",;".contains($0) }) {
            let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let first: Int?, last: Int?
            if ends.count == 1 { first = Int(ends[0]); last = first }
            else { first = ends[0].isEmpty ? 1 : Int(ends[0]); last = ends[1].isEmpty ? pageCount : Int(ends[1]) }
            guard let a = first, let b = last, a >= 1 else { continue }
            let range = a <= b ? Array(a...b) : Array((b...a).reversed())
            for page in range where page <= pageCount && seen.insert(page - 1).inserted { result.append(page - 1) }
        }
        return result
    }
}
