import SuperConverterCore
import EbookKit

// EbookKit's checks (WP-E). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerEbookKitTests()`, which main.swift already calls.
func registerEbookKitTests() {
    SelfTest.cases.append(("EbookKit.installs", {
        EbookKitModule.install()
    }))
}
