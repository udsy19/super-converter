import SuperConverterCore
import MathKit

// MathKit's checks (WP-T). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerMathKitTests()`, which main.swift already calls.
func registerMathKitTests() {
    SelfTest.cases.append(("MathKit.installs", {
        MathKitModule.install()
    }))
}
