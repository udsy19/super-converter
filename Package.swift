// swift-tools-version:5.10
import Foundation
import PackageDescription

// Super Converter — every conversion on the Mac, 212 formats. The package is self-contained (no dependency on the sister
// apps' repositories) and builds with the Command Line Tools only. Engines depend on SuperConverterCore and their vendor
// libraries; feature modules reach each other through the `Services` registry. See docs/ARCHITECTURE.md for who owns what
// and docs/specs/ for behaviour, look, wording and licences.

// Engines (ARCHITECTURE §3, §4): no app policy (no `Services`, no `Defaults`, no UI strings), configured through
// initialisers; each registers its converters in `<Module>Module.install()`.
let engines = [
    "ImageKit",       // Core Image / vImage / ColorSync pipeline, RAW, encoders, PSB/XCF/PPM codecs, icon sets
    "VectorKit",      // VectorDocument readers (PDF, SVG, EMF/WMF, SK/SK1) and writers (PDF, SVG, PS/EPS, EMF, WMF, CGM)
    "XPSKit",         // XPS/OpenXPS/DWFx reader, XPS writer
    "VectorizeKit",   // raster → SVG tracing (vtracer port)
    "CADKit",         // DXF reader/writer, CAD model, plotting, DWF readers
    "DocKit",         // DocModel readers and writers
    "TypesetKit",     // DocModel/Workbook/Publication → PDF with the LaTeX look
    "MathKit",        // MathJax in JavaScriptCore → SVG paths
    "LayoutKit",      // PDF → LayoutDocument (copied from Super PDF)
    "RenderKit",      // PDF page rasterising, PDF/A, ColorSync output (copied from Super PDF)
    "OfficeKit",      // Workbook, Deck, ODF drawing pictures, Zip/XML/OOXML support
    "EbookKit",       // Publication readers and writers
    "ArchiveKit",     // ArchiveTree over libarchive and 7zz; own decoders; extraction safety
    "MediaKit",       // probing, AVFoundation pipelines, FFmpeg adapter, animation, SoundFont reader
    "FontKit",        // SFNT/CFF/WOFF/WOFF2/EOT/SVG-font readers and writers
    "HelperKit",      // helper catalog runtime, detection, one-click installer, process runner, app automation
    "UpdateKit",      // GitHub Releases updater (copied from Super Flow)
]

// Feature modules (ARCHITECTURE §3): depend on Core only, except ConvertKit, which registers every engine's converters.
let features = [
    "ConvertKit",     // planner, job queue, work folders, output policy, sniffer, thumbnails, PDF routes
    "WindowKit",      // the main window
    "MenuBarKit",     // status item, drop target, panel
    "SettingsKit",    // Settings window panes
]

// Engine-to-engine edges (ARCHITECTURE §4; mirrored by `ModuleGraph.engineEdges`, which the self-test checks against the
// imports under Sources/): no cycles.
let engineEdges: [String: [String]] = [
    "TypesetKit": ["MathKit", "VectorKit"],
    "DocKit": ["LayoutKit"],
    "EbookKit": ["DocKit", "TypesetKit"],
    "CADKit": ["VectorKit"],
    "XPSKit": ["VectorKit"],
    "ImageKit": ["RenderKit"],
    "OfficeKit": ["TypesetKit", "RenderKit"],
]

// Vendor libraries (formats §3.3): static xcframeworks (LibRaw: one dynamic library) built by scripts/build-vendor.sh
// and fetched by scripts/fetch-vendor.sh into the git-ignored Vendor/. A library that has not been fetched is left out
// (with the engines' dependency on it), so the rest of the package still builds; an engine that imports a missing
// module then fails with "no such module", and `scripts/fetch-vendor.sh` fixes it. Module names equal the framework names:
// WebP (libwebp + mux/demux), AVIF (libavif + SVT-AV1 + dav1d), Archive (libarchive + xz, zstd, lz4), XLS (libxls),
// WOFF2 (woff2 + Brotli, C shim), UnALZ (unalz, C shim), LibRaw (libraw_r.dylib, with the X3F tools).
let vendorRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor")
func vendorIsFetched(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: vendorRoot.appendingPathComponent("\(name).xcframework").path)
}
// Engine -> the vendor libraries it links (formats §3.3, "Used by").
let engineVendorLibraries: [String: [String]] = [
    "ImageKit": ["WebP", "AVIF", "LibRaw"],
    "ArchiveKit": ["Archive", "UnALZ"],
    "OfficeKit": ["XLS"],
    "FontKit": ["WOFF2"],
]
let vendorTargets: [Target] = Set(engineVendorLibraries.values.joined()).sorted().filter(vendorIsFetched).map {
    .binaryTarget(name: $0, path: "Vendor/\($0).xcframework")
}

// What each engine links besides the Core and the engines it may import.
let engineDependencies: [String: [Target.Dependency]] = engineVendorLibraries.mapValues {
    $0.filter(vendorIsFetched).map { .target(name: $0) }
}

let package = Package(
    name: "SuperConverter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SuperConverter", targets: ["SuperConverter"]),
        .executable(name: "sconv", targets: ["sconv"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "SuperConverterCore", path: "Sources/SuperConverterCore"),

        // The app: launch sequence, module wiring, menus, Dock, Open With, Services, URL routes, `Services.updates`.
        .executableTarget(
            name: "SuperConverter",
            dependencies: ["SuperConverterCore"] + (features + engines).map { .target(name: $0) },
            path: "Sources/SuperConverter"),
        // Finder Quick Actions: one executable that scripts/build-app.sh packages as six action extensions, entered
        // through NSExtensionMain as Xcode links appexes.
        .executableTarget(
            name: "SuperConverterQuickActions", dependencies: ["SuperConverterCore", "MenuBarKit"], path: "Sources/SuperConverterQuickActions",
            exclude: ["Plists"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        // The command-line tool: the same engines, for scripts and the quality bench.
        .executableTarget(
            name: "sconv",
            dependencies: ["SuperConverterCore", "ConvertKit"] + engines.map { .target(name: $0) },
            path: "Sources/sconv"),
        // The quality bench (quality §9).
        .executableTarget(
            name: "SuperConverterQualityBench",
            dependencies: ["SuperConverterCore", "ConvertKit"] + engines.map { .target(name: $0) },
            path: "Sources/SuperConverterQualityBench"),
        // Headless checks (the Command Line Tools have no XCTest): `swift run SuperConverterSelfTest`.
        .executableTarget(
            name: "SuperConverterSelfTest",
            dependencies: ["SuperConverterCore"] + (features + engines).map { .target(name: $0) },
            path: "Sources/SuperConverterSelfTest"),
    ]
    + vendorTargets
    + engines.map { name in
        .target(name: name,
                dependencies: ["SuperConverterCore"] + (engineEdges[name] ?? []).map { .target(name: $0) }
                    + (engineDependencies[name] ?? []),
                path: "Sources/\(name)")
    }
    + features.map { name in
        .target(name: name,
                dependencies: ["SuperConverterCore"] + (name == "ConvertKit" ? engines.map { .target(name: $0) } : []),
                path: "Sources/\(name)")
    }
)
