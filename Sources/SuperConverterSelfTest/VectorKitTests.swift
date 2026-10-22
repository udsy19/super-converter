import SuperConverterCore
import VectorKit

// VectorKit's checks (WP-V). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerVectorKitTests()`, which main.swift already calls.
func registerVectorKitTests() {
    SelfTest.cases.append(("VectorKit.installs", {
        VectorKitModule.install()
    }))
}
