import Foundation
import SuperConverterCore

/// The `7zz` adapter (formats §3.3): reads what libarchive cannot (AES-encrypted 7Z/ZIP, encrypted RAR, ARJ, IMG with
/// FAT/NTFS/MBR/GPT, UDF, Quantum CAB) and writes the encrypted ZIP/7Z targets. 7zz runs through HelperKit's runner
/// (`Services.tools`, ARCHITECTURE §7); a password goes to it on standard input, never on the command line.
enum SevenZip {
    static func isAvailable(_ tools: (any ToolRunning)?) -> Bool { tools?.location(of: .sevenZip) != nil }

    private static func run(_ tools: (any ToolRunning)?, _ arguments: [String], scratch: URL, writable: [URL] = [], input: Data? = nil,
                            outputLimit: Int = 256_000, isCancelled: @escaping @Sendable () -> Bool) async throws -> HelperRunResult {
        try await ToolCall.run(tools, .sevenZip, arguments, scratch: scratch, writable: writable, input: input, outputLimit: outputLimit,
                               isCancelled: isCancelled)
    }

    // MARK: Reading

    static func read(_ request: ArchiveReadRequest) async throws -> ArchiveTree {
        let scratch = request.root.deletingLastPathComponent().appendingPathComponent(".7zz-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let listing = try await run(request.tools, ["l", "-slt", "-ba", "-sccUTF-8", "-scsUTF-8"] + passwordArguments(request.password) + ["--", request.source.path],
                                    scratch: scratch, input: stdin(request.password), outputLimit: 64 << 20, isCancelled: request.isCancelled)
        if listing.exitCode != 0 && listing.exitCode != 1 { throw failure(listing) }
        let items = parseListing(listing.standardOutput)
        try checkLimits(items, request: request)
        let encrypted = items.contains { $0.encrypted }
        if encrypted && request.password == nil { throw ArchiveError.passwordRequired }

        let extractor = try request.extractor()
        let extraction = try await run(request.tools, ["x", "-y", "-bd", "-bb0", "-aoa", "-sccUTF-8", "-scsUTF-8", "-o" + request.root.path]
                                       + passwordArguments(request.password) + ["--", request.source.path],
                                       scratch: scratch, writable: [request.root], input: stdin(request.password), isCancelled: request.isCancelled)
        if extraction.exitCode != 0 && extraction.exitCode != 1 { throw failure(extraction) }
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

    private static func failure(_ result: HelperRunResult) -> ArchiveError {
        let text = result.standardOutput + result.standardError
        if text.contains("Wrong password") || text.contains("Cannot open encrypted archive") || text.contains("Enter password") {
            return .passwordRequired
        }
        if text.contains("Unsupported Method") || text.contains("Unsupported feature") { return .unsupported("This archive uses a method that isn’t supported.") }
        if text.contains("Cannot find the archive") || text.contains("No such file") { return .failed("The archive couldn’t be found.") }
        return .damaged(text.split(separator: "\n").first(where: { $0.hasPrefix("ERROR") }).map(String.init) ?? "Couldn’t read the archive.")
    }

    // MARK: Writing

    /// Writes an encrypted ZIP (AES-256) or 7Z (AES-256, names encrypted too) from the staged tree.
    static func write(_ request: ArchiveWriteRequest, staged: URL, scratch: URL) async throws {
        guard let password = request.password else { throw ArchiveError.failed("No password given.") }
        let level = switch request.compression { case .fast: "1"; case .normal: "5"; case .smallest: "9" }
        var arguments = ["a", "-y", "-bd", "-bb0", "-snl", "-mx=\(level)", "-sccUTF-8", "-scsUTF-8"]
        switch request.format.rawValue {
        case "zip": arguments += ["-tzip", "-mem=AES256"]
        case "7z": arguments += ["-t7z", "-mhe=on"]
        default: throw ArchiveError.unsupported("Passwords aren’t supported for \(request.format.rawValue.uppercased()).")
        }
        // 7zz asks for the password twice when creating an encrypted archive. `<staged>/*` stores every item of the staged
        // folder (dot files and subfolders included) under its name relative to that folder.
        arguments += ["-p", "--", request.destination.path, staged.path + "/*"]
        let result = try await run(request.tools, arguments, scratch: scratch, writable: [request.destination.deletingLastPathComponent()],
                                   input: Data("\(password)\n\(password)\n".utf8), isCancelled: request.isCancelled)
        if result.exitCode != 0 && result.exitCode != 1 {
            throw ArchiveError.failed((result.standardOutput + result.standardError).split(separator: "\n").first(where: { $0.hasPrefix("ERROR") }).map(String.init) ?? "7-Zip couldn’t write the archive.")
        }
    }
}
