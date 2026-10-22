import SuperConverterCore

/// CADKit: DXF reader and writer, the CAD model, plotting to VectorDocument, DWF readers (ARCHITECTURE §3). A engine: it carries no app policy and registers its converters in `install()`.
public enum CADKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
