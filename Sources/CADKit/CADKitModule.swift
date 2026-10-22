import SuperConverterCore
import Foundation

/// CADKit: DXF reader and writer, the CAD model, plotting to VectorDocument, DWF readers (ARCHITECTURE §3). An engine: it carries no app policy and registers its converters in `install()`.
public enum CADKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {
        for converter in CADKitConverters.all { Services.converters.register(converter) }
    }
}

/// Hooks for CADKit's self-test: values the checks compare against without making the internals public API.
public enum CADKitProbe {
    public static func aci(_ index: Int) -> (Int, Int, Int) { let c = ACI.rgb(index); return (c.r, c.g, c.b) }
    public static func isBinaryDXF(_ data: Data) -> Bool { DXFGroups.isBinary(data) }
}
