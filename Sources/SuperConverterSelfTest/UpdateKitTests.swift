import SuperConverterCore
import UpdateKit

// UpdateKit's checks (WP0a). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerUpdateKitTests()`, which main.swift already calls.
func registerUpdateKitTests() {
    SelfTest.cases.append(("UpdateKit.installs", {
        UpdateKitModule.install()
    }))
}
