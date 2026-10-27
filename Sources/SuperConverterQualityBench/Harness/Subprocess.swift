import Foundation

/// Runs a command line tool to completion (the bench's only use of other processes: ffmpeg, zip, unzip).
enum Subprocess {
    struct Output {
        var status: Int32
        var standardOutput: String?
        var standardError: String?
        var data: Data
    }

    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], currentDirectory: URL? = nil, timeout: TimeInterval = 300) -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        process.standardInput = FileHandle.nullDevice
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { outData = data } else { errData = data }
                group.leave()
            }
        }
        do { try process.run() } catch { return Output(status: -1, standardOutput: nil, standardError: "\(error)", data: Data()) }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        group.wait()
        return Output(status: process.terminationStatus, standardOutput: String(data: outData, encoding: .utf8),
                      standardError: String(data: errData, encoding: .utf8), data: outData)
    }
}

/// The repository checkout the bench runs from (found from this file's compile-time path; `SUPERCONVERTER_REPO` overrides).
enum RepoRoot {
    static let url: URL = {
        if let path = ProcessInfo.processInfo.environment["SUPERCONVERTER_REPO"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }()
    static var corpus: URL { url.appendingPathComponent("Tests/Corpus", isDirectory: true) }
    static var golden: URL { url.appendingPathComponent("Tests/Golden", isDirectory: true) }
    /// Reports and run memory (git-ignored).
    static var quality: URL { url.appendingPathComponent(".build/quality", isDirectory: true) }
}
