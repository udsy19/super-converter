import SuperConverterCore
import DocKit

// DocKit's checks (WP-D). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerDocKitTests()`, which main.swift already calls.
func registerDocKitTests() {
    SelfTest.cases.append(("DocKit.installs", {
        DocKitModule.install()
    }))
}
