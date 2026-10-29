import Foundation
import SuperConverterCore

/// ArchiveKit: ArchiveTree over libarchive and 7zz, own decoders, extraction safety (ARCHITECTURE §3). An engine: it carries
/// no app policy and registers its converters in `install()`.
public enum ArchiveKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2). HelperKit installs
    /// first and leaves its runner in `Services.tools`, through which 7zz and hdiutil run (ARCHITECTURE §7).
    @MainActor public static func install() {
        let tools: (any ToolRunning)? = Services.tools
        for engine in ArchiveConverter.engines { Services.converters.register(ArchiveConverter(engine, tools: tools)) }
    }

    /// What EbookKit unpacks RAR comics and CHM books with (its `ArchiveExtractor`): 7zz for CHM, libarchive (falling back
    /// to 7zz) for everything else, under the same extraction limits as every other read. Call after HelperKit installs.
    @MainActor public static func extractor() -> @Sendable (_ archive: URL, _ destination: URL) async throws -> Void {
        let tools: (any ToolRunning)? = Services.tools
        return { archive, destination in
            let format = FormatID(archive.pathExtension.lowercased())
            do {
                _ = try await Archives.read(ArchiveReadRequest(source: archive, format: format, root: destination, tools: tools),
                                            engine: format == "chm" ? .sevenZip : .libarchive)
            } catch let error as ArchiveError {
                throw error.conversionError(for: format)
            }
        }
    }
}
