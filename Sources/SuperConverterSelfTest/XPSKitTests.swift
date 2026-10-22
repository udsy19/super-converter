import SuperConverterCore
import XPSKit

// XPSKit's checks (WP-V). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerXPSKitTests()`, which main.swift already calls.
func registerXPSKitTests() {
    SelfTest.cases.append(("XPSKit.installs", {
        XPSKitModule.install()
    }))
}
