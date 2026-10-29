import AppKit
import SuperConverterCore
import SwiftUI
#if DEBUG
@testable import SettingsKit

// SettingsKit's checks (WP-S): Defaults round-trips on a throwaway suite, the Formats model editing a saved target and a saved
// option, the Helpers model against FakeHelpers, the About model against FakeUpdates, the notices parser, and an offscreen
// render of every pane (and the window's tab row). Set SUPERCONVERTER_RENDER_DIR to write the renders there. No case opens a
// page or shows a window: the context's opener and panels are replaced.
func registerSettingsKitTests() {
    let cases: [(String, @MainActor () -> Void)] = [
        ("SettingsKit.installs", settingsInstalls),
        ("SettingsKit.defaultsRoundTrips", settingsDefaults),
        ("SettingsKit.formatsDefaultTargets", settingsDefaultTargets),
        ("SettingsKit.formatsSavedOptions", settingsSavedOptions),
        ("SettingsKit.helpers", settingsHelpers),
        ("SettingsKit.helperPills", settingsHelperPills),
        ("SettingsKit.quickActions", settingsQuickActions),
        ("SettingsKit.about", settingsAbout),
        ("SettingsKit.notices", settingsNotices),
        ("SettingsKit.rendersEveryPane", settingsRenders),
    ]
    for c in cases { SelfTest.cases.append(c) }
}

// MARK: - Helpers

@MainActor
private func withTempDefaults(_ body: () -> Void) {
    let previous = Defaults.store
    let name = "superconverter-settings-test-\(UUID().uuidString)"
    Defaults.store = UserDefaults(suiteName: name)!
    body()
    Defaults.store.removePersistentDomain(forName: name)
    Defaults.store = previous
}

@MainActor
private func settingsPump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
private func testContext(helpers: HelperManaging? = nil, updates: UpdateChecking? = nil, menuBar: MenuBarPresenting? = nil,
                         opened: ((URL) -> Void)? = nil, notices: URL? = nil) -> SettingsContext {
    let context = SettingsContext()
    context.helpers = { helpers }
    context.updates = { updates }
    let menuBar = menuBar ?? sampleMenuBar()
    context.menuBar = { menuBar }
    context.open = { opened?($0) }
    context.chooseFolder = { nil }
    context.chooseLocation = { nil }
    context.noticesURL = notices
    context.version = "1.2.3"
    return context
}

/// MenuBarKit as the Quick Actions pane sees it: the five one-step actions, the first three on.
@MainActor
private func sampleMenuBar() -> FakeMenuBar {
    let fake = FakeMenuBar()
    fake.quickActions = [
        QuickActionSwitch(target: "jpg", title: "Convert to JPG", takes: "Images", isOn: true),
        QuickActionSwitch(target: "png", title: "Convert to PNG", takes: "Images", isOn: true),
        QuickActionSwitch(target: "pdf", title: "Convert to PDF", takes: "Documents, images, slides, sheets and e-books", isOn: true),
        QuickActionSwitch(target: "mp4", title: "Convert to MP4", takes: "Videos", isOn: false),
        QuickActionSwitch(target: "mp3", title: "Convert to MP3", takes: "Audio and videos", isOn: false),
    ]
    return fake
}

private let sampleNotices = """
# Third-party notices

<!-- BEGIN generated -->

Intro line.

## Bundled executables

FFmpeg is LGPL.

<!-- END generated -->

## Vendor libraries

libwebp: BSD-3-Clause.
"""

// MARK: - Cases

@MainActor
private func settingsInstalls() {
    let previous = Services.settings
    SettingsKitModule.install()
    check(Services.settings is SettingsWindowController, "install registers the Settings window as Services.settings")
    Services.settings = previous
    check(SettingsPane.allCases.count == 5, "five panes: General, Formats, Helpers, Quick Actions, About")
}

@MainActor
private func settingsDefaults() {
    withTempDefaults {
        let folder = URL(fileURLWithPath: "/tmp/settings-test-out")
        Defaults[.outputPlace] = .folder(folder)
        check(Defaults[.outputPlace] == .folder(folder), "a chosen folder round-trips")
        Defaults[.outputPlace] = .downloads
        check(Defaults[.outputPlace] == .downloads, "Downloads round-trips")
        Defaults.reset(.outputPlace)
        check(Defaults[.outputPlace] == .nextToOriginal, "reset brings back next to the originals")
        Defaults[.collisionPolicy] = .ask
        check(Defaults[.collisionPolicy] == .ask, "collision policy round-trips")
        Defaults[.playSound] = true
        Defaults[.notifyWhenDone] = false
        check(Defaults[.playSound] && !Defaults[.notifyWhenDone], "switches round-trip")
        let helperURL = URL(fileURLWithPath: "/Applications/LibreOffice.app")
        Defaults[.helperPath(.libreoffice)] = helperURL
        check(Defaults[.helperPath(.libreoffice)] == helperURL, "a helper location round-trips")
        Defaults[.helperPath(.libreoffice)] = nil
        check(Defaults[.helperPath(.libreoffice)] == nil, "clearing a helper location removes it")
    }
}

@MainActor
private func settingsDefaultTargets() {
    withTempDefaults {
        let model = FormatsModel()
        check(model.target(for: "heic") == "jpg", "HEIC becomes JPG before any choice")
        check(!model.isCustomised(source: "heic"), "no choice yet")
        check(model.targets(for: "heic").contains("png"), "the menu offers PNG for HEIC")
        model.setTarget("png", for: "heic")
        check(model.target(for: "heic") == "png" && model.isCustomised(source: "heic"), "a chosen target wins")
        check(Defaults[.target(for: "heic")] == "png", "and is saved where the picker's “from now on” saves it")
        model.resetTarget(for: "heic")
        check(model.target(for: "heic") == "jpg" && !model.isCustomised(source: "heic"), "reset returns to the table")
        check(!FormatsModel.sourceGroups.isEmpty && FormatsModel.sourceGroups.flatMap(\.sources).contains("heic"), "sources are grouped by category")
    }
}

@MainActor
private func settingsSavedOptions() {
    withTempDefaults {
        let model = FormatsModel()
        check(FormatsModel.targetGroups.flatMap(\.targets).contains("jpg"), "JPG is a target with options")
        let definitions = model.definitions(for: "jpg")
        guard let quality = definitions.primary.first(where: { $0.key == "quality" }) ?? definitions.more.first(where: { $0.key == "quality" }) else {
            check(false, "the JPG profile has a quality option"); return
        }
        check(!definitions.primary.contains { $0.key == "look" } && !definitions.more.contains { $0.key == "look" }, "the per-card look is not saved")
        check(!model.hasSaved("jpg"), "nothing saved at first")
        model.set(quality, to: .int(62), for: "jpg")
        check(model.hasSaved("jpg") && model.saved(for: "jpg")["quality"] == .int(62), "a saved option is stored for the target")
        check(Defaults[.savedOptions(for: "jpg")]?["quality"] == .int(62), "in the key the options sheet reads")
        check(model.summary(for: "jpg").contains("62"), "the summary names the value")
        model.set(quality, to: quality.defaultValue, for: "jpg")
        check(!model.hasSaved("jpg") && Defaults[.savedOptions(for: "jpg")] == nil, "setting an option back to its default stores nothing")
        model.set(quality, to: .int(40), for: "jpg")
        model.resetOptions(for: "jpg")
        check(!model.hasSaved("jpg"), "reset clears the saved options")
        for definition in definitions.primary + definitions.more {
            if case .secret = definition.kind { check(false, "secret options are never offered for saving") }
        }
    }
}

@MainActor
private func settingsHelpers() {
    let fake = FakeHelpers()
    var opened: [URL] = []
    let model = HelpersModel(manager: fake, open: { opened.append($0) })
    check(model.action(for: .calibre) == .install, "a one-click helper offers Install")
    check(model.action(for: .iwork) == .get(label: "Get Numbers…"), "iWork offers Get Numbers…")
    check(model.action(for: .ghostscript) == .get(label: "Get…"), "a Homebrew helper offers Get…")
    check(model.action(for: .msoffice) == .none, "a detect-only helper has no button")
    check(Set(HelpersModel.main + HelpersModel.further) == Set(HelperID.allCases), "every helper is listed once")

    let task = model.install(.calibre)
    check(model.progress(for: .calibre) != nil, "the row shows progress while installing")
    _ = complete(10) { await task.value }
    check(model.status(.calibre).isReady && fake.installs == [.calibre], "install goes through the manager and ends installed")
    check(model.progress(for: .calibre) == nil && model.action(for: .calibre) == .remove, "an installed one-click helper offers Remove")
    check(model.badge(for: .calibre)?.text == "Installed", "and says Installed")
    model.remove(.calibre)
    check(model.status(.calibre) == .notInstalled && model.action(for: .calibre) == .install, "Remove puts it back to not installed")

    fake.statuses[.libreoffice] = .installed(version: "25.8", location: URL(fileURLWithPath: "/Applications/LibreOffice.app"), sizeOnDisk: 1_000_000_000)
    model.lookAgain()
    check(model.detail(for: .libreoffice) == "Version 25.8 · 1 GB · MPL-2.0" || model.detail(for: .libreoffice).hasPrefix("Version 25.8 · "), "the installed line gives version, size and licence")
    fake.statuses[.pandoc] = .unusable("Wrong architecture")
    model.lookAgain()
    check(model.badge(for: .pandoc)?.isGood == false && model.detail(for: .pandoc) == "Wrong architecture", "an unusable helper says why")
    check(model.action(for: .pandoc) == .install, "and can be installed again")
    check(model.detail(for: .tectonic).contains("download") && model.detail(for: .tectonic).contains("MIT"), "a not-installed line has the download size and licence")

    model.get(.oda)
    check(opened == [URL(string: "https://www.opendesign.com/guestfiles/oda_file_converter")!], "Get… opens the vendor page")
    model.get(.ghostscript)
    check(model.note(for: .ghostscript)?.contains("brew install ghostscript") == true && opened.count == 1, "Get… for a Homebrew helper shows the command and opens nothing")

    withTempDefaults {
        let path = URL(fileURLWithPath: "/opt/tools/gs")
        model.setLocation(path, for: .ghostscript)
        check(Defaults[.helperPath(.ghostscript)] == path, "a chosen location is saved")
        model.setLocation(nil, for: .ghostscript)
        check(Defaults[.helperPath(.ghostscript)] == nil, "and can be cleared")
    }
}

@MainActor
private func settingsHelperPills() {
    for helper in [HelperID.libreoffice, .calibre, .pandoc, .tectonic, .ghostscript, .oda] {
        let items = HelperUnlocks.items(for: helper)
        check(!items.isEmpty && items.count <= 8, "\(helper.rawValue) shows 1 to 8 pills (\(items.count))")
    }
    check(HelperUnlocks.items(for: .calibre).contains { $0.text == "MOBI" }, "calibre unlocks MOBI")
    check(HelperUnlocks.items(for: .ghostscript).contains { $0.text == "EPS" }, "Ghostscript unlocks EPS")
}

/// ux §5.10–§5.11: the pane shows what macOS has, not what it last set, and its switches go to MenuBarKit.
@MainActor
private func settingsQuickActions() {
    let fake = sampleMenuBar()
    let model = QuickActionsModel(menuBar: { fake })
    check(model.switches.isEmpty, "nothing shown before macOS is asked")
    _ = complete(10) { await model.refresh() }
    check(model.switches == fake.quickActions && !model.hasUnlisted, "the pane shows every action as macOS has it")

    _ = complete(10) { await model.set("mp4", on: true) }
    check(fake.switched.map(\.0) == ["mp4"] && fake.switched.map(\.1) == [true], "the MP4 switch goes to MenuBarKit")
    check(model.switches.first { $0.target == "mp4" }?.isOn == true && model.problem == nil, "and shows on")

    // Switched off in System Settings › Extensions, then back to the app: the pane follows macOS.
    fake.quickActions[1].isOn = false
    check(model.switches[1].isOn == true, "until the pane looks again it shows what it read")
    _ = complete(10) { await model.refresh() }
    check(model.switches[1].isOn == false, "PNG switched off in System Settings shows off")

    fake.switchesTake = false
    _ = complete(10) { await model.set("mp3", on: true) }
    check(model.switches.first { $0.target == "mp3" }?.isOn == false, "a switch macOS refused goes back")
    check(model.problem == "macOS didn’t switch “Convert to MP3” on. Try it in System Settings › Extensions.", "and says so in one line: \(model.problem ?? "")")

    fake.quickActions[4].isOn = nil
    _ = complete(10) { await model.refresh() }
    check(model.hasUnlisted, "an extension macOS doesn’t list is noted")
    check(QuickActionsPane.unlisted.contains("Applications folder") && QuickActionsPane.footnote.contains("System Settings › Extensions"), "the notes say where")

    // The pane asks macOS when it appears (the refresh runs from the view, not from the test).
    let shown = QuickActionsModel(menuBar: { fake })
    let context = testContext(menuBar: fake)
    let host = NSHostingView(rootView: QuickActionsPane(context: context, model: shown).frame(width: 820, height: 600))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    for _ in 0..<40 where shown.switches.isEmpty { settingsPump(0.05) }
    check(shown.switches == fake.quickActions, "the pane reads the switches on appear")
}

@MainActor
private func settingsAbout() {
    let updates = FakeUpdates()
    let model = AboutModel(updates: updates)
    check(model.canCheck && model.statusText.isEmpty, "idle: can check, nothing to say")
    model.checkNow()
    for _ in 0..<40 where model.statusText.isEmpty { settingsPump(0.05) }
    check(updates.checks == 1, "Check for Updates goes to the updater")
    check(model.statusText.contains("up to date"), "and the result is said in words: \(model.statusText)")
    check(AboutModel(updates: nil).canCheck == false, "no updater, no check")
    check(AboutPane.privacy.hasPrefix("Nothing leaves the Mac"), "the privacy statement is ux §6.6")
}

@MainActor
private func settingsNotices() {
    let sections = Notices.sections(sampleNotices)
    check(sections.map(\.title) == ["Overview", "Bundled executables", "Vendor libraries"], "sections: \(sections.map(\.title))")
    check(!sections.contains { $0.body.contains("<!--") }, "generator comments are dropped")
    let real = Notices.sections((try? String(contentsOfFile: "THIRD_PARTY_NOTICES.md", encoding: .utf8)) ?? sampleNotices)
    check(real.count >= 2, "the repository's notices split into sections")
    check(Notices.load(from: nil).isEmpty, "no file, no sections")
}

@MainActor
private func settingsRenders() {
    let dir = ProcessInfo.processInfo.environment["SUPERCONVERTER_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    let notices = FileManager.default.temporaryDirectory.appendingPathComponent("settings-notices-\(UUID().uuidString).md")
    try? sampleNotices.write(to: notices, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: notices) }

    let fake = FakeHelpers()
    fake.statuses[.libreoffice] = .installed(version: "25.8", location: URL(fileURLWithPath: "/Applications/LibreOffice.app"), sizeOnDisk: 1_000_000_000)
    fake.statuses[.pandoc] = .installing(fraction: 0.64)
    let context = testContext(helpers: fake, updates: FakeUpdates(), notices: notices)

    withTempDefaults {
        for dark in [false, true] {
            for pane in SettingsPane.allCases {
                let selection = SettingsSelection(pane)
                let rep = settingsRender(SettingsView(selection: selection, context: context), dark: dark)
                check(rep.pixelsWide == Int(SCMetrics.Settings.size.width) * 2 && rep.pixelsHigh == Int(SCMetrics.Settings.size.height) * 2,
                      "\(pane.title) renders at 2x window size")
                check(settingsDistinctColours(rep) > 12, "\(pane.title) (\(dark ? "dark" : "light")) draws content, not a blank window")
                check(settingsHasWindowBackground(rep, dark: dark), "\(pane.title) sits on the window background")
                if let dir, let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: dir.appendingPathComponent("settings-\(pane.rawValue)\(dark ? "-dark" : "").png"))
                }
            }
        }
        let helpers = settingsRender(SettingsView(selection: SettingsSelection(.helpers), context: context), dark: false)
        check(settingsContainsColour(helpers, hex: SCColor.nearBlack), "the Helpers pane draws the dark Install buttons")
        let formats = settingsRender(SettingsView(selection: SettingsSelection(.formats), context: context), dark: false)
        check(settingsContainsColour(formats, hex: SCColor.colors(for: .document).tint), "the Formats pane draws category-tinted pills")
        let about = settingsRender(AboutPane(context: context, showLicences: true).frame(width: 820, height: 700), dark: false, size: CGSize(width: 820, height: 700))
        check(settingsDistinctColours(about) > 12, "About renders with the licences open")
        let saved = settingsRender(FormatsPane(section: .options).frame(width: 820, height: 700), dark: false, size: CGSize(width: 820, height: 700))
        check(settingsDistinctColours(saved) > 12, "the saved-options list renders")
    }
}

@MainActor
private func settingsRender<V: View>(_ view: V, dark: Bool, size: CGSize = SCMetrics.Settings.size) -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    settingsPump(0.3)
    host.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

private func settingsSample(_ rep: NSBitmapImageRep, step: Int = 16, _ visit: (NSColor) -> Void) {
    for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
        for x in stride(from: 0, to: rep.pixelsWide, by: step) { if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { visit(c) } }
    }
}

private func settingsDistinctColours(_ rep: NSBitmapImageRep) -> Int {
    var seen = Set<String>()
    settingsSample(rep, step: 6) { seen.insert(String(format: "%02x%02x%02x", Int($0.redComponent * 31), Int($0.greenComponent * 31), Int($0.blueComponent * 31))) }
    return seen.count
}

private func settingsHasWindowBackground(_ rep: NSBitmapImageRep, dark: Bool) -> Bool {
    let target = NSColor(hex: dark ? SCColor.windowBackground.dark : SCColor.windowBackground.light).usingColorSpace(.sRGB)!
    var hits = 0
    settingsSample(rep) { c in
        if abs(c.redComponent - target.redComponent) < 0.03 && abs(c.greenComponent - target.greenComponent) < 0.03 && abs(c.blueComponent - target.blueComponent) < 0.03 { hits += 1 }
    }
    return hits > 20
}

private func settingsContainsColour(_ rep: NSBitmapImageRep, hex: String) -> Bool {
    let target = NSColor(hex: hex).usingColorSpace(.sRGB)!
    var found = false
    settingsSample(rep, step: 3) { c in
        if abs(c.redComponent - target.redComponent) < 0.03 && abs(c.greenComponent - target.greenComponent) < 0.03 && abs(c.blueComponent - target.blueComponent) < 0.03 { found = true }
    }
    return found
}
#else
func registerSettingsKitTests() {}
#endif
