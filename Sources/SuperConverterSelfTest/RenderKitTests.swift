import SuperConverterCore
import RenderKit

// RenderKit's checks (WP-L). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerRenderKitTests()`, which main.swift already calls.
func registerRenderKitTests() {
    SelfTest.cases.append(("RenderKit.installs", {
        RenderKitModule.install()
    }))
}
