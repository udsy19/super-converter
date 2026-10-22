import SuperConverterCore
import ArchiveKit

// ArchiveKit's checks (WP-A). Pre-wired by WP1: the module's owner replaces the smoke case with its own cases and keeps
// `registerArchiveKitTests()`, which main.swift already calls.
func registerArchiveKitTests() {
    SelfTest.cases.append(("ArchiveKit.installs", {
        ArchiveKitModule.install()
    }))
}
