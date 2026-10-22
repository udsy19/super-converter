import SuperConverterCore
import OfficeKit

// OfficeKit's checks (WP-O). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerOfficeKitTests()`, which main.swift already calls.
func registerOfficeKitTests() {
    SelfTest.cases.append(("OfficeKit.installs", {
        OfficeKitModule.install()
    }))
}
