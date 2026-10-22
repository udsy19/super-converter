import SuperConverterCore
import LayoutKit

// LayoutKit's checks (WP-L). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerLayoutKitTests()`, which main.swift already calls.
func registerLayoutKitTests() {
    SelfTest.cases.append(("LayoutKit.installs", {
        LayoutKitModule.install()
    }))
}
