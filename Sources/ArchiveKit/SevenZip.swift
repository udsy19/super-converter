import Foundation
import SuperConverterCore

/// The `7zz` adapter (formats §3.3): reads what libarchive cannot (AES-encrypted 7Z/ZIP, encrypted RAR, ARJ, IMG with
/// FAT/NTFS/MBR/GPT, UDF, Quantum CAB) and writes the encrypted ZIP/7Z targets. A password goes to 7zz on its standard
/// input, never on the command line.
enum SevenZip {
    /// `Contents/Helpers/7zz` in the app, `Vendor/Tools/7zz` in a checkout, or the path in `SUPERCONVERTER_7ZZ`.
    static func locate() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SUPERCONVERTER_7ZZ"] { candidates.append(URL(fileURLWithPath: override)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz"))
        var folder = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(folder.appendingPathComponent("Vendor/Tools/7zz"))
            folder.deleteLastPathComponent()
        }
        // The checkout this module was built from (package root = three levels above this file).
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/Tools/7zz"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { locate() != nil }

    // MARK: Reading

    static func read(_ request: ArchiveReadRequest) throws -> ArchiveTree {
        guard let tool = locate() else { throw ArchiveError.toolMissing("7-Zip") }
        let scratch = request.root.deletingLastPathComponent().appendingPathComponent(".7zz-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let listing = try ToolRunner.run(tool, arguments: ["l", "-slt", "-ba", "-sccUTF-8", "-scsUTF-8"] + passwordArguments(request.password) + ["--", request.source.path],
                                         standardInput: stdin(request.password), scratch: scratch, isCancelled: request.isCancelled)
        if listing.status != 0 && listing.status != 1 { throw failure(listing, hasPassword: request.password != nil, format: request.format) }
        let items = parseListing(listing.text)
        try checkLimits(items, request: request)
        let encrypted = items.contains { $0.encrypted }
        if encrypted && request.password == nil { throw ArchiveError.passwordRequired }

        let extractor = try request.extractor()
        let run = try ToolRunner.run(tool, arguments: ["x", "-y", "-bd", "-bb0", "-aoa", "-sccUTF-8", "-scsUTF-8", "-o" + request.root.path]
                                     + passwordArguments(request.password) + ["--", request.source.path],
                                     standardInput: stdin(request.password), scratch: scratch, isCancelled: request.isCancelled)
        if run.status != 0 && run.status != 1 { throw failure(run, hasPassword: request.password != nil, format: request.format) }
        try extractor.adoptExtractedTree()
        return extractor.finish(wasEncrypted: encrypted)
    }

    /// A line-per-field listing (`l -slt`): one block per item, separated by blank lines.
    struct Item { var path = "", size: Int64 = 0, isFolder = false, encrypted = false }

    static func parseListing(_ text: String) -> [Item] {
        var items: [Item] = []
        var current = Item(), seen = false
        func flush() { if seen { items.append(current) }; current = Item(); seen = false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            guard let eq = line.range(of: " = ") else { continue }
            let key = line[..<eq.lowerBound], value = String(line[eq.upperBound...])
            switch key {
            case "Path": seen = true; current.path = value
            case "Size": current.size = Int64(value) ?? 0
            case "Folder": current.isFolder = value == "+"
            case "Encrypted": current.encrypted = value == "+"
            default: break
            }
        }
        flush()
        return items
    }

    private static func checkLimits(_ items: [Item], request: ArchiveReadRequest) throws {
        let limits = request.limits
        if items.count > limits.maxEntries { throw ArchiveError.tooLarge("This archive holds more than \(limits.maxEntries) items, which is more than Super Converter will unpack.") }
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        if total > limits.maxTotalBytes { throw ArchiveError.tooLarge("This archive unpacks to more than \(Formatting.bytes(limits.maxTotalBytes)), which is more than Super Converter will unpack.") }
        let size = request.sourceSize
        if total > limits.ratioFloor, size > 0, Double(total) > limits.maxRatio * Double(size) {
            throw ArchiveError.tooLarge("This archive expands far more than a real one does (a decompression bomb), so it was stopped.")
        }
        if let free = try? request.root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           total + limits.reserveBytes > free {
            throw ArchiveError.notEnoughSpace(needed: total + limits.reserveBytes)
        }
    }

    /// With no password a throw-away one is passed so 7zz never stops to ask on a terminal; an encrypted archive then fails
    /// with "wrong password", which maps to `passwordRequired`.
    private static func passwordArguments(_ password: String?) -> [String] { password == nil ? ["-pSC-no-password-given"] : [] }
    private static func stdin(_ password: String?) -> Data? { password.map { Data(($0 + "\n").utf8) } }

    private static func failure(_ result: ToolResult, hasPassword: Bool, format: FormatID) -> ArchiveError {
        let text = result.text + result.standardError
        if text.contains("Wrong password") || text.contains("Cannot open encrypted archive") || text.contains("Enter password") {
            return .passwordRequired
        }
        if text.contains("Unsupported Method") || text.contains("Unsupported feature") { return .unsupported("This archive uses a method that isn’t supported.") }
        if text.contains("Cannot find the archive") || text.contains("No such file") { return .failed("The archive couldn’t be found.") }
        return .damaged(text.split(separator: "\n").first(where: { $0.hasPrefix("ERROR") }).map(String.init) ?? "Couldn’t read the archive.")
    }

    // MARK: Writing

    /// Writes an encrypted ZIP (AES-256) or 7Z (AES-256, names encrypted too) from the staged tree.
    static func write(_ request: ArchiveWriteRequest, staged: URL, scratch: URL) throws {
        guard let tool = locate() else { throw ArchiveError.toolMissing("7-Zip") }
        guard let password = request.password else { throw ArchiveError.failed("No password given.") }
        let level = switch request.compression { case .fast: "1"; case .normal: "5"; case .smallest: "9" }
        var arguments = ["a", "-y", "-bd", "-bb0", "-snl", "-mx=\(level)", "-sccUTF-8", "-scsUTF-8"]
        switch request.format.rawValue {
        case "zip": arguments += ["-tzip", "-mem=AES256"]
        case "7z": arguments += ["-t7z", "-mhe=on"]
        default: throw ArchiveError.unsupported("Passwords aren’t supported for \(request.format.rawValue.uppercased()).")
        }
        // 7zz asks for the password twice when creating an encrypted archive.
        arguments += ["-p", "--", request.destination.path, "."]
        let result = try ToolRunner.run(tool, arguments: arguments, currentDirectory: staged, standardInput: Data("\(password)\n\(password)\n".utf8),
                                        scratch: scratch, isCancelled: request.isCancelled)
        if result.status != 0 && result.status != 1 {
            throw ArchiveError.failed((result.text + result.standardError).split(separator: "\n").first(where: { $0.hasPrefix("ERROR") }).map(String.init) ?? "7-Zip couldn’t write the archive.")
        }
    }
}
