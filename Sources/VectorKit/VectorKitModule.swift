import SuperConverterCore

/// VectorKit: VectorDocument readers and writers (PDF, SVG, PostScript/EPS, EMF, WMF, CGM, SK/SK1) (ARCHITECTURE §3). A engine: it carries no app policy and registers its converters in `install()`.
public enum VectorKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
