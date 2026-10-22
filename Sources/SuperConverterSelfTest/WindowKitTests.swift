import SuperConverterCore
import WindowKit

// WindowKit's checks (WP-U). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerWindowKitTests()`, which main.swift already calls.
func registerWindowKitTests() {
    SelfTest.cases.append(("WindowKit.installs", {
        WindowKitModule.install()
    }))
}
