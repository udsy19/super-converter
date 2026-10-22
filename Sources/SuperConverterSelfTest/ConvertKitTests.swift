import SuperConverterCore
import ConvertKit

// ConvertKit's checks (WP-P). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerConvertKitTests()`, which main.swift already calls.
func registerConvertKitTests() {
    SelfTest.cases.append(("ConvertKit.installs", {
        ConvertKitModule.install()
    }))
}
