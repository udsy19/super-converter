import SuperConverterCore

// The app target's checks (WP-R): launch sequence order, Info.plist document types for all 212 formats, URL routes.
// Pre-wired by WP1; WP-R replaces the smoke case and keeps `registerAppTests()`.
func registerAppTests() {
    SelfTest.cases.append(("App.paths", {
        check(SuperConverterPaths.bundleID == "com.udsy.superconverter", "bundle identifier")
    }))
}
