import SuperConverterCore
import SettingsKit

// SettingsKit's checks (WP-S). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerSettingsKitTests()`, which main.swift already calls.
func registerSettingsKitTests() {
    SelfTest.cases.append(("SettingsKit.installs", {
        SettingsKitModule.install()
    }))
}
