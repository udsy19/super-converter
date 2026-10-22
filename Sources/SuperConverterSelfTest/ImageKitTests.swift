import SuperConverterCore
import ImageKit

// ImageKit's checks (WP-I). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerImageKitTests()`, which main.swift already calls.
func registerImageKitTests() {
    SelfTest.cases.append(("ImageKit.installs", {
        ImageKitModule.install()
    }))
}
