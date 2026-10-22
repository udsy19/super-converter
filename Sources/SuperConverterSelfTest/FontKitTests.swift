import SuperConverterCore
import FontKit

// FontKit's checks (WP-F). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerFontKitTests()`, which main.swift already calls.
func registerFontKitTests() {
    SelfTest.cases.append(("FontKit.installs", {
        FontKitModule.install()
    }))
}
