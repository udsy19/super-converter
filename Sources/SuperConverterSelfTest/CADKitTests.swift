import SuperConverterCore
import CADKit

// CADKit's checks (WP-C). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerCADKitTests()`, which main.swift already calls.
func registerCADKitTests() {
    SelfTest.cases.append(("CADKit.installs", {
        CADKitModule.install()
    }))
}
