import SuperConverterCore

/// ConvertKit: planner, job queue, work folders, output policy, sniffer, thumbnails and the PDF routes (ARCHITECTURE §3). A feature module: it talks to the others through `Services`.
public enum ConvertKitModule {
    /// Assigns this module's services in `Services` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
