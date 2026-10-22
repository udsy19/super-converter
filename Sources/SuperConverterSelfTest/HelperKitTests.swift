import SuperConverterCore
import HelperKit

// HelperKit's checks (WP-H). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerHelperKitTests()`, which main.swift already calls.
func registerHelperKitTests() {
    SelfTest.cases.append(("HelperKit.installs", {
        HelperKitModule.install()
    }))
}
