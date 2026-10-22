import Foundation
import SuperConverterCore

/// ConvertKit: planner, job queue, work folders, output policy, sniffer, thumbnails and the PDF routes (ARCHITECTURE §3). A feature module: it talks to the others through `Services`.
public enum ConvertKitModule {
    /// What the matrix and the registry disagreed about at launch (every engine installs its converters before this runs).
    @MainActor public private(set) static var coverage = CoverageReport()
    @MainActor private static var statusWatcher: Task<Void, Never>?

    /// Assigns this module's services in `Services` (ARCHITECTURE §9, launch step 2) and verifies the matrix against the
    /// registry. Run it after HelperKit and every engine module have installed.
    @MainActor public static func install(collisionPolicy: @escaping () -> CollisionPolicy = { Defaults[.collisionPolicy] }) {
        let helperStatus: (HelperID) -> HelperStatus = { Services.helpers?.status(of: $0) ?? .notInstalled }
        let planner = Planner(registry: Services.converters, helperReady: { helperStatus($0).isReady })
        let output = OutputRules(collisionPolicy: collisionPolicy)
        Services.planner = planner
        Services.output = output
        Services.sniffer = FormatSniffer()
        Services.thumbnails = ThumbnailService()
        Services.queue = JobQueue(registry: Services.converters, output: output, helperStatus: helperStatus,
                                  helperChanges: Services.helpers?.statusChanges)

        sweepStaleWorkFolders()

        // Availability is computed now and again whenever a helper changes.
        statusWatcher?.cancel()
        if let changes = Services.helpers?.statusChanges {
            statusWatcher = Task { @MainActor in
                for await _ in changes { planner.refresh() }
            }
        }

        coverage = Coverage.verify(Services.converters.converters)
        if !coverage.isComplete {
            Log.planner.notice("Matrix and registry differ: \(coverage.missingEngines.count) engines without a converter, \(coverage.unusedConverters.count) converters no route uses, \(coverage.unhandledSteps.count) steps unhandled")
        }
    }

    /// Deletes work folders whose process is gone (launch step 4, ARCHITECTURE §9). A running job's folder is locked, so a
    /// second process (the app and `sconv` at once) never loses its work.
    @MainActor @discardableResult
    public static func sweepStaleWorkFolders(in jobs: URL = SuperConverterPaths.jobs) -> Int { WorkFolder.sweepStale(in: jobs) }
}
