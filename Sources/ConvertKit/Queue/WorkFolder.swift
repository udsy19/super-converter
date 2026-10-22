import Darwin
import Foundation
import SuperConverterCore

/// A job's private work folder under `Jobs/<uuid>/` (ARCHITECTURE §8): the only place a step writes. It holds a locked
/// `.lock` file while its job lives, so a sweep (at launch, or by another process such as `sconv`) can tell a folder whose
/// owner died from one still in use.
final class WorkFolder: @unchecked Sendable {
    let url: URL
    private var descriptor: Int32

    init(_ job: JobID) {
        url = SuperConverterPaths.job(job)
        descriptor = open(url.appendingPathComponent(Self.lockName).path, O_CREAT | O_RDWR, 0o600)
        if descriptor >= 0 { flock(descriptor, LOCK_EX | LOCK_NB) }
    }

    /// Deletes the folder and everything in it (partial output included).
    func remove() {
        try? FileManager.default.removeItem(at: url)
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }

    private static let lockName = ".lock"

    /// Removes work folders no live process owns. Returns how many it removed.
    @discardableResult
    static func sweepStale(in jobs: URL = SuperConverterPaths.jobs) -> Int {
        let fileManager = FileManager.default
        var removed = 0
        for folder in (try? fileManager.contentsOfDirectory(at: jobs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let lock = open(folder.appendingPathComponent(lockName).path, O_RDWR)
            if lock >= 0 {
                defer { close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { continue }   // its owner is alive
            } else {
                // Created a moment ago and not locked yet: leave it.
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard Date().timeIntervalSince(modified) > 60 else { continue }
            }
            if (try? fileManager.removeItem(at: folder)) != nil { removed += 1 }
        }
        return removed
    }
}
