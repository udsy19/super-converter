import Foundation
import SuperConverterCore

/// HelperKit: helper catalog runtime, detection, one-click installer, process runner, app automation (ARCHITECTURE §3). An
/// engine: it carries no app policy and registers its converters in `install()`.
public enum HelperKitModule {
    /// Creates `Services.helpers` and registers the converter of every helper-run engine with `Services.converters`
    /// (ARCHITECTURE §9, launch step 2). `override` is the path a person set in Settings › Helpers (the app target reads it
    /// from `Defaults`; engines never do).
    @MainActor public static func install(override: @escaping @Sendable (HelperID) -> URL? = { _ in nil }) {
        let service = HelperService(override: override)
        Services.helpers = service
        for converter in service.converters() { Services.converters.register(converter) }
    }
}
