import SuperConverterCore
import TypesetKit

// TypesetKit's checks (WP-T). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerTypesetKitTests()`, which main.swift already calls.
func registerTypesetKitTests() {
    SelfTest.cases.append(("TypesetKit.installs", {
        TypesetKitModule.install()
    }))
}
