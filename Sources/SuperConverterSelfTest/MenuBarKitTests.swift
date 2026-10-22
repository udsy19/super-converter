import SuperConverterCore
import MenuBarKit

// MenuBarKit's checks (WP-B). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerMenuBarKitTests()`, which main.swift already calls.
func registerMenuBarKitTests() {
    SelfTest.cases.append(("MenuBarKit.installs", {
        MenuBarKitModule.install()
    }))
}
