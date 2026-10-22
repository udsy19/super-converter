import SuperConverterCore
import VectorizeKit

// VectorizeKit's checks (WP-V). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerVectorizeKitTests()`, which main.swift already calls.
func registerVectorizeKitTests() {
    SelfTest.cases.append(("VectorizeKit.installs", {
        VectorizeKitModule.install()
    }))
}
