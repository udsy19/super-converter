import SuperConverterCore
import MediaKit

// MediaKit's checks (WP-M). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerMediaKitTests()`, which main.swift already calls.
func registerMediaKitTests() {
    SelfTest.cases.append(("MediaKit.installs", {
        MediaKitModule.install()
    }))
}
