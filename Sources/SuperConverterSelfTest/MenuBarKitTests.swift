import AppKit
import SuperConverterCore
import SwiftUI
import UniformTypeIdentifiers
#if DEBUG
@testable import MenuBarKit

// MenuBarKit's checks (WP-B): the Quick Actions' activation rules per UTType, the extension plists, links handed to the app
// through a fake opener, the Services entries, the Quick Action switches against a fake pluginkit, background conversions
// against a scripted queue, the panel's model, and an offscreen render of the panel. Nothing opens an app or a URL, posts a
// notification, registers a Service or extension, switches an extension, or touches the real settings or recent list (a
// temporary Defaults suite and recent.json). SUPERCONVERTER_RENDER_DIR writes the panel renders; SUPERCONVERTER_WRITE_PLISTS=1
// rewrites Sources/SuperConverterQuickActions/Plists from `QuickAction.infoPlist`.
func registerMenuBarKitTests() {
    let cases: [(String, @MainActor () -> Void)] = [
        ("MenuBarKit.installs", menuBarInstalls),
        ("MenuBarKit.activationRules", menuBarActivationRules),
        ("MenuBarKit.activationCoversCatalog", menuBarActivationCoversCatalog),
        ("MenuBarKit.extensionPlists", menuBarExtensionPlists),
        ("MenuBarKit.quickActionsHandOff", menuBarHandOff),
        ("MenuBarKit.services", menuBarServices),
        ("MenuBarKit.quickActionSwitches", menuBarSwitches),
        ("MenuBarKit.quickActionsFirstLaunch", menuBarFirstLaunch),
        ("MenuBarKit.backgroundConversion", menuBarBackground),
        ("MenuBarKit.recentList", menuBarRecents),
        ("MenuBarKit.panelModel", menuBarPanelModel),
        ("MenuBarKit.panelRender", menuBarPanelRender),
    ]
    for c in cases { SelfTest.cases.append(c) }
}

// MARK: - Test doubles

/// pluginkit as macOS answers it, for the Quick Action extensions only: `-m -i <id>` lists the extension with its election,
/// `-e use|ignore -i <id>` changes it. Every run is recorded; nothing reaches the real pluginkit.
private final class FakePluginKit: ToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    /// "+" use, "-" ignore, " " no election; an id missing here isn't listed.
    private var elections: [String: Character]
    private var runs: [[String]] = []
    /// Runs of `-e` that fail (macOS refusing the change).
    var electionsFail = false

    init(_ elections: [QuickAction: Character]) {
        self.elections = Dictionary(uniqueKeysWithValues: elections.map { ($0.bundleID, $1) })
    }

    subscript(action: QuickAction) -> Character? {
        get { lock.withLock { elections[action.bundleID] } }
        set { lock.withLock { elections[action.bundleID] = newValue } }
    }

    /// The arguments of every run since the last call, and forgets them.
    func takeRuns() -> [[String]] { lock.withLock { defer { runs = [] }; return runs } }

    func location(of tool: BundledTool) -> URL? { tool == .pluginkit ? URL(fileURLWithPath: "/usr/bin/pluginkit") : nil }

    func run(_ invocation: ToolInvocation) async throws -> HelperRunResult {
        guard invocation.tool == .pluginkit else { throw ConversionError.failed("only pluginkit here") }
        return lock.withLock {
            runs.append(invocation.arguments)
            switch invocation.arguments {
            case let a where a.count == 3 && a[0] == "-m" && a[1] == "-i":
                guard let election = elections[a[2]] else { return HelperRunResult(exitCode: 0) }
                return HelperRunResult(exitCode: 0, standardOutput: "\(election)    \(a[2])(1.0.0)\n")
            case let a where a.count == 4 && a[0] == "-e" && a[2] == "-i" && ["use", "ignore"].contains(a[1]):
                if electionsFail { return HelperRunResult(exitCode: 1, standardError: "match: no matches") }
                if elections[a[3]] != nil { elections[a[3]] = a[1] == "use" ? "+" : "-" }
                return HelperRunResult(exitCode: 0)
            default:
                return HelperRunResult(exitCode: 64, standardError: "usage")
            }
        }
    }
}

private final class FakeOpener: URLOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

@MainActor
private final class RecordingNotifier: BatchNotifying {
    private(set) var posted: [(title: String, body: String, reveal: URL?)] = []
    func post(title: String, body: String, reveal: URL?) { posted.append((title, body, reveal)) }
}

/// A queue that runs every job at once: started, half way, then the outcome the test chose for its plan.
@MainActor
private final class ScriptedQueue: JobQueueing {
    private(set) var enqueued: [(plan: ConversionPlan, place: OutputPlace)] = []
    var outcome: (ConversionPlan) -> Result<ConversionResult, ConversionError> = { plan in
        .success(ConversionResult(outputs: [plan.request.source.deletingPathExtension().appendingPathExtension(plan.request.target.rawValue)],
                                  inputBytes: 2_000_000, outputBytes: 500_000))
    }
    let events: AsyncStream<JobEvent>
    private let continuation: AsyncStream<JobEvent>.Continuation
    init() {
        var captured: AsyncStream<JobEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }
    var activeCount: Int { 0 }
    func enqueue(_ plan: ConversionPlan, into place: OutputPlace) -> JobID {
        let id = JobID()
        enqueued.append((plan, place))
        continuation.yield(.queued(id))
        continuation.yield(.started(id))
        continuation.yield(.progress(id, JobProgress(fraction: 0.5)))
        switch outcome(plan) {
        case .success(let result): continuation.yield(.finished(id, result))
        case .failure(let error): continuation.yield(.failed(id, error))
        }
        return id
    }
    func cancel(_ job: JobID) {}
    func cancelAll() {}
}

/// Fresh fakes, a throwaway Defaults suite and recent list; `Services` points at them.
@MainActor
private struct MenuBarFixture {
    let queue = ScriptedQueue()
    let sniffer = FakeSniffer()
    let notifier = RecordingNotifier()
    let converter: BackgroundConverter
    let recentFile = FileManager.default.temporaryDirectory.appendingPathComponent("menubarkit-recent-\(UUID().uuidString).json")

    init() {
        installFakes()
        Services.queue = queue
        Services.sniffer = sniffer
        Services.planner = StubPlanner()
        Defaults.store = UserDefaults(suiteName: "superconverter-menubarkit-\(UUID().uuidString)")!
        converter = BackgroundConverter(recents: RecentList(file: recentFile), notifier: notifier)
    }

    func file(_ name: String, bytes: Int64 = 2_000_000) -> URL {
        let url = URL(fileURLWithPath: "/tmp/superconverter-menubar/\(name)")
        let format = FormatCatalog.format(forFileName: name)?.id
        sniffer.results[url] = SniffResult(format: format, claimed: format, sizeBytes: bytes)
        return url
    }

    func cleanUp() { try? FileManager.default.removeItem(at: recentFile) }
}

// MARK: - Cases

@MainActor private func menuBarInstalls() {
    installFakes()
    MenuBarKitModule.install()
    check(Services.menuBar is MenuBarController, "install() registers the controller")
    check((Services.menuBar as? MenuBarController)?.statusItem == nil, "no status item until the app installs it")
}

/// ux §5.10: which files each action shows for, by UTType.
@MainActor private func menuBarActivationRules() {
    let docx = UTType("org.openxmlformats.wordprocessingml.document")!
    let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet")!
    let pptx = UTType("org.openxmlformats.presentationml.presentation")!
    let epub = UTType("org.idpf.epub-container")!
    let table: [(QuickAction, shows: [UTType], hides: [UTType])] = [
        (.convertWith, [.png, .pdf, .zip, .mp3, .movie, docx, .folder], []),
        (.toJPG, [.heic, .png, .tiff, .gif, .webP, .rawImage], [.pdf, .mpeg4Movie, .mp3, .plainText, docx, .zip]),
        (.toPNG, [.heic, .jpeg, .tiff, .gif, .webP, .svg], [.pdf, .mpeg4Movie, .mp3, .plainText, docx, .zip]),
        (.toPDF, [.png, .heic, .plainText, .rtf, .html, docx, xlsx, pptx, epub], [.pdf, .mp3, .mpeg4Movie, .quickTimeMovie, .zip]),
        (.toMP4, [.quickTimeMovie, .mpeg4Movie, .avi], [.png, .pdf, .mp3, .wav, .plainText, .zip]),
        (.toMP3, [.wav, .aiff, .mpeg4Audio, .quickTimeMovie, .mpeg4Movie], [.png, .pdf, .plainText, docx, .zip]),
    ]
    for (action, shows, hides) in table {
        for type in shows { check(action.accepts(type), "\(action.title) shows for \(type.identifier)") }
        for type in hides { check(!action.accepts(type), "\(action.title) hides for \(type.identifier)") }
    }
    // What a file can become, by format.
    check(QuickAction.toPDF.takes("docx") && QuickAction.toPDF.takes("jpg") && QuickAction.toPDF.takes("epub") && !QuickAction.toPDF.takes("pdf"),
          "Convert to PDF takes documents, images and books, not PDFs")
    check(QuickAction.toJPG.takes("heic") && !QuickAction.toJPG.takes("jpg") && !QuickAction.toJPG.takes("jpeg") && !QuickAction.toJPG.takes("docx"),
          "Convert to JPG takes other images; a JPEG is a JPG")
    check(QuickAction.toMP3.takes("mov") && QuickAction.toMP3.takes("wav") && !QuickAction.toMP3.takes("mp3"), "Convert to MP3 takes audio and video")
    check(QuickAction.toMP4.takes("mov") && !QuickAction.toMP4.takes("wav"), "Convert to MP4 takes video")
    check(QuickAction.convertWith.takes("ttf") && QuickAction.convertWith.takes("dwg"), "Convert with Super Converter takes every format")
    // The rules are what the extensions carry.
    for action in QuickAction.allCases {
        let rule = action.activationRule
        check(action.activationTypes.allSatisfy { rule.contains("\"\($0)\"") } && !action.activationTypes.isEmpty, "\(action.title): the rule lists its types")
        check(rule.hasPrefix("SUBQUERY(extensionItems,") && rule.contains("UTI-CONFORMS-TO"), "\(action.title): an extension activation rule")
    }
    check(QuickAction.convertWith.activationTypes == ["public.item"], "the window action shows for every item")
    check(QuickAction.toJPG.activationTypes.contains("public.image") && QuickAction.toMP3.activationTypes.contains("public.audio"), "image and audio actions use the system types")
    check(!QuickAction.toPDF.activationTypes.contains("com.adobe.pdf"), "a PDF is not offered Convert to PDF")
}

/// Every format an action takes that has a system type is shown the action (the table has no holes).
@MainActor private func menuBarActivationCoversCatalog() {
    for action in QuickAction.allCases where action.target != nil {
        let missed = FormatCatalog.inputs.filter { action.takes($0.id) }.flatMap { format in
            format.utTypes.filter { !action.accepts($0) }.map { "\(format.id.rawValue) (\($0.identifier))" }
        }
        check(missed.isEmpty, "\(action.title) misses: \(missed.joined(separator: ", "))")
    }
}

@MainActor private func menuBarExtensionPlists() {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SuperConverterQuickActions/Plists", isDirectory: true)
    if ProcessInfo.processInfo.environment["SUPERCONVERTER_WRITE_PLISTS"] == "1" {
        for action in QuickAction.allCases {
            (action.infoPlist as NSDictionary).write(to: folder.appendingPathComponent(action.bundleName + ".plist"), atomically: true)
        }
    }
    let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "plist" }
    check(Set(files.map { $0.deletingPathExtension().lastPathComponent }) == Set(QuickAction.allCases.map(\.bundleName)), "one plist per Quick Action")
    check(QuickAction.allCases.map(\.title) == ["Convert with Super Converter…", "Convert to JPG", "Convert to PNG", "Convert to PDF", "Convert to MP4", "Convert to MP3"],
          "ux §5.10's names, in menu order")
    for action in QuickAction.allCases {
        guard let info = NSDictionary(contentsOf: folder.appendingPathComponent(action.bundleName + ".plist")) as? [String: Any] else {
            check(false, "\(action.bundleName).plist reads"); continue
        }
        check((info as NSDictionary).isEqual(to: action.infoPlist), "\(action.bundleName).plist is what the catalog writes (SUPERCONVERTER_WRITE_PLISTS=1 rewrites it)")
        check(QuickAction(bundleInfo: info) == action, "\(action.title): the plist says which action it is")
        check(info["CFBundleIdentifier"] as? String == action.bundleID && action.bundleID.hasPrefix(SuperConverterPaths.bundleID + "."), "\(action.title): id under the app's")
        check(info["CFBundleExecutable"] as? String == "SuperConverterQuickActions" && info["CFBundlePackageType"] as? String == "XPC!", "\(action.title): the shared executable")
        let ext = info["NSExtension"] as? [String: Any] ?? [:]
        let attributes = ext["NSExtensionAttributes"] as? [String: Any] ?? [:]
        check(ext["NSExtensionPointIdentifier"] as? String == "com.apple.services" && ext["NSExtensionPrincipalClass"] as? String == "QuickActionRequestHandler",
              "\(action.title): a Finder action entered through its handler")
        check(attributes["NSExtensionActivationRule"] as? String == action.activationRule, "\(action.title): its activation rule")
        check(attributes["NSExtensionServiceAllowsFinderPreviewItem"] as? Bool == true, "\(action.title): in Finder's Quick Actions")
    }
    check(Set(QuickAction.allCases.map(\.bundleID)).count == 6, "six distinct bundle ids")
    check(QuickAction(bundleInfo: nil) == nil && QuickAction(bundleInfo: ["SuperConverterQuickAction": "nope"]) == nil, "an unknown plist names no action")
    // The first three are on at first launch (ux §5.10).
    let on = QuickAction.allCases.compactMap { action in action.startsOn.map { (action, $0) } }
    check(on.map(\.0) == [.toJPG, .toPNG, .toPDF, .toMP4, .toMP3] && on.map(\.1) == [true, true, true, false, false], "JPG, PNG and PDF start on; MP4 and MP3 off")
}

/// Quick Actions hand files to the app: one link through the opener, nothing else.
@MainActor private func menuBarHandOff() {
    let a = URL(fileURLWithPath: "/Users/me/Beach at golden hour.heic"), b = URL(fileURLWithPath: "/Users/me/Ünïcode & more/日本.heic")
    let opener = FakeOpener()
    check(QuickAction.toJPG.handOff([a, b], using: opener), "Convert to JPG hands the files over")
    check(opener.opened.count == 1, "one link for the whole selection")
    let link = opener.opened.first.flatMap(QuickActionLink.init)
    check(link == QuickActionLink(.convert, files: [a, b], target: "jpg"), "the link converts both files, in order, to JPG")
    check(opener.opened.first?.scheme == "superconverter" && opener.opened.first?.host == "convert", "a superconverter://convert link")

    let window = FakeOpener()
    check(QuickAction.convertWith.handOff([a], using: window), "Convert with Super Converter… hands the file over")
    check(window.opened.first.flatMap(QuickActionLink.init) == QuickActionLink(.open, files: [a]), "and asks the app to open it in the window")
    check(window.opened.first?.host == "open", "a superconverter://open link")

    let none = FakeOpener()
    check(!QuickAction.toPDF.handOff([], using: none) && none.opened.isEmpty, "nothing selected, nothing opened")
    for action in QuickAction.allCases where action.target != nil {
        check(QuickActionLink(action, files: [a]).target == action.target && QuickActionLink(action, files: [a]).verb == .convert, "\(action.title) converts to \(action.target!.pill)")
    }
    check(QuickActionLink(URL(string: "https://example.com/convert?file=/a")!) == nil, "other URLs are not links")
    check(QuickActionLink(URL(string: "superconverter://convert?to=jpg")!) == nil, "a link without files is not a link")
    check(QuickActionLink(URL(string: "superconverter://convert?file=relative.png")!) == nil, "files are absolute paths")
    check(QuickActionLink(URL(string: "superconverter://settings?file=/a")!) == nil, "unknown verbs are not links")

    // The app routes a link: open → the window; convert → a background run.
    let fixture = MenuBarFixture(); defer { fixture.cleanUp() }
    let fakeWindow = FakeWindow()
    Services.window = fakeWindow
    check(MenuBarKitModule.handle(QuickActionLink(.open, files: [a]).url), "the module handles an open link")
    check(fakeWindow.added.count == 1 && fakeWindow.added[0].urls == [a] && fakeWindow.shown == 1, "the window gets the files and comes forward")
    check(!MenuBarKitModule.handle(URL(string: "superconverter://nothing")!), "the module declines other URLs")
}

@MainActor private func menuBarServices() {
    let entries = QuickAction.servicesEntries
    check(entries.count == 6, "six Services entries")
    let provider = ServicesProvider(dispatch: { _ in })
    for action in QuickAction.allCases {
        let entry = action.servicesEntry
        check((entry["NSMenuItem"] as? [String: String])?["default"] == action.title, "\(action.title): its menu title")
        check(entry["NSSendFileTypes"] as? [String] == action.activationTypes, "\(action.title): the same types as the Quick Action")
        check(entry["NSPortName"] as? String == "Super Converter", "\(action.title): served by the app")
        let message = entry["NSMessage"] as? String ?? ""
        check(provider.responds(to: Selector("\(message):userData:error:")), "\(action.title): the provider answers \(message)")
    }
    check(Set(entries.compactMap { $0["NSMessage"] as? String }).count == 6, "six distinct messages")

    // A Service reads file URLs from its pasteboard and runs the link; nothing touches the general pasteboard.
    let board = NSPasteboard(name: NSPasteboard.Name("superconverter-selftest-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let file = URL(fileURLWithPath: "/tmp/superconverter-menubar/a.heic")
    board.clearContents()
    board.writeObjects([file as NSURL])
    check(ServicesProvider.files(on: board) == [file], "files come off the pasteboard")
    var ran: [QuickActionLink] = []
    let live = ServicesProvider(dispatch: { ran.append($0) })
    var message: NSString = ""
    live.convertToJPG(board, userData: "", error: &message)
    let deadline = Date().addingTimeInterval(2)
    while ran.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    check(ran == [QuickActionLink(.convert, files: [file], target: "jpg")], "Convert to JPG runs a convert link")
    board.clearContents()
    live.convertToPNG(board, userData: "", error: &message)
    check(message != "" && ran.count == 1, "an empty pasteboard is an error, not a run")
}

@MainActor private func menuBarBackground() {
    let f = MenuBarFixture(); defer { f.cleanUp() }
    Defaults[.outputPlace] = .downloads
    let heic = f.file("Beach at golden hour.heic"), jpg = f.file("Already.jpg"), doc = f.file("Report.docx"), unknown = f.file("mystery.zzz")
    // Convert to JPG: the JPG is left alone, the unreadable file is reported, the others run through the queue.
    guard let summary = complete(10, { await f.converter.convert([heic, jpg, unknown], target: "jpg").value }).flatMap({ try? $0.get() }) else {
        check(false, "the background run finishes"); return
    }
    check(f.queue.enqueued.count == 1 && f.queue.enqueued[0].plan.request.target == "jpg" && f.queue.enqueued[0].plan.request.source == heic,
          "only the HEIC runs, to JPG")
    check(f.queue.enqueued.first?.place == .downloads, "results go where Settings says")
    check(summary.total == 2 && summary.succeeded.count == 1 && summary.failures.count == 1, "one converted, one unreadable")
    check(f.notifier.posted.count == 1, "one notification for the batch")
    check(f.notifier.posted.first?.title == "Done. 1 of 2 files converted", "its title is the batch summary: \(f.notifier.posted.first?.title ?? "")")
    check(f.notifier.posted.first?.body.contains("in Downloads") == true && f.notifier.posted.first?.body.contains("1 needs attention") == true,
          "its detail says where and what needs attention: \(f.notifier.posted.first?.body ?? "")")
    check(f.notifier.posted.first?.reveal?.lastPathComponent == "Beach at golden hour.jpg", "Show reveals the first result")
    check(f.converter.recents.load().map(\.name) == ["Beach at golden hour.jpg"], "the result joins the recent list")

    // Each file without a preset goes to its own default (ux §6.1).
    let both = complete(10, { await f.converter.convert([heic, doc], target: nil).value }).flatMap { try? $0.get() }
    check(f.queue.enqueued.suffix(2).map(\.plan.request.target) == ["jpg", "pdf"], "HEIC → JPG and DOCX → PDF by default")
    check(both?.succeeded.count == 2 && f.notifier.posted.last?.title == "Done. 2 of 2 files converted", "both converted")
    check(f.converter.recents.load().count == 3, "the recent list grows")

    // A failure says why, in one line.
    f.queue.outcome = { _ in .failure(.passwordRequired("docx")) }
    _ = complete(10) { await f.converter.convert([doc], target: "pdf").value }
    check(f.notifier.posted.last?.title == "Didn’t convert" && f.notifier.posted.last?.body == "“Report.docx”: This DOCX needs its password", "a failed run names the file and the problem: \(f.notifier.posted.last?.body ?? "")")

    // "Notify when done" off: nothing is posted.
    Defaults[.notifyWhenDone] = false
    let before = f.notifier.posted.count
    f.queue.outcome = { plan in .success(ConversionResult(outputs: [plan.request.source], inputBytes: 1, outputBytes: 1)) }
    _ = complete(10) { await f.converter.convert([heic], target: "jpg").value }
    check(f.notifier.posted.count == before, "no notification when the setting is off")
}

@MainActor private func menuBarRecents() {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("menubarkit-recent-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let list = RecentList(file: file)
    check(list.load().isEmpty, "no file, no recents")
    let now = Date()
    let made = (0..<12).map { RecentConversion(sourceName: "f\($0).docx", sourceFormat: "docx", output: URL(fileURLWithPath: "/tmp/f\($0).pdf"), date: now) }
    list.add(Array(made[0..<6])); list.add(Array(made[6..<12]))
    let loaded = list.load()
    check(loaded.count == 10, "the last ten are kept")
    check(loaded.first?.name == "f11.pdf" && loaded.last?.name == "f2.pdf", "newest first, the oldest dropped")
    check(loaded.first?.sourceFormat == "docx" && abs(loaded[0].date.timeIntervalSince(now)) < 1, "format and date round-trip")
    check(RecentList.ago(now.addingTimeInterval(-20), now: now) == "just now", "under a minute reads \"just now\"")
    check(RecentList.ago(now.addingTimeInterval(-120), now: now).contains("2") && RecentList.ago(now.addingTimeInterval(-600), now: now).contains("10"), "minutes read as in the mockup")
    try? Data("not json".utf8).write(to: file)
    check(list.load().isEmpty, "a damaged file reads as empty")
}

@MainActor private func menuBarPanelModel() {
    let f = MenuBarFixture(); defer { f.cleanUp() }
    let model = PanelModel(converter: f.converter)
    var revealed: [[URL]] = [], openedApp = 0, openedSettings = 0
    model.reveal = { revealed.append($0) }
    model.openApp = { openedApp += 1 }
    model.openSettings = { openedSettings += 1 }
    check(model.phase == .idle && model.subtitle == nil, "an empty panel is idle")

    let heic = f.file("Beach at golden hour.heic"), mov = f.file("Screen recording 2026-10-22.mov"), junk = f.file("mystery.zzz")
    model.add([heic, mov, junk])
    check(model.phase == .ready && model.subtitle == "3 files dropped", "dropped files make a ready panel: \(model.subtitle ?? "")")
    check(model.items.map(\.target) == ["jpg", "mp4", nil], "default targets: HEIC → JPG, MOV → MP4, unreadable has none")
    check(model.items[2].state == .unreadable, "an unreadable file stays, marked")
    check(model.convertTitle == "Convert 2 files" && model.buttonCategories == [.image, .video], "the button counts what can run and takes the targets' colours")
    check(model.placeLine == "Saved next to the originals", "saved next to the originals by default")
    check(model.targets(for: model.items[0]).contains("png") && model.targets(for: model.items[2]).isEmpty, "the pill offers the file's targets")

    model.setTarget("png", for: model.items[0])
    check(model.items[0].target == "png" && Defaults[.target(for: "heic")] == "png", "a changed target is remembered for the format")
    model.setPlace(.downloads)
    check(Defaults[.outputPlace] == .downloads && model.placeLine == "Saved in Downloads", "Change… sets the place")
    model.chooseFolder = { URL(fileURLWithPath: "/tmp/Invoices") }
    model.chooseOutputFolder()
    check(model.placeLine == "Saved in “Invoices”", "a chosen folder is named")
    model.remove(model.items[1])
    check(model.items.count == 2 && model.convertTitle == "Convert 1 file", "a file can be removed before converting")

    // Converting with the panel closed: results, recents, one notification.
    model.isShown = false
    model.convert()
    check(model.running != nil, "converting starts")
    _ = complete(10) { await model.running?.value }
    check(model.phase == .finished && model.subtitle == "1 of 2 converted", "the panel ends finished: \(model.subtitle ?? "")")
    check(f.queue.enqueued.map(\.plan.request.target) == ["png"] && f.queue.enqueued.first?.place == .folder(URL(fileURLWithPath: "/tmp/Invoices")), "the run used the chosen target and place")
    check(f.notifier.posted.count == 1, "a run that ends with the panel closed notifies")
    check(model.recents.map(\.name) == ["Beach at golden hour.png"], "the recent list shows the result")
    model.reveal(model.recents.map(\.output))
    check(revealed.count == 1, "Show in Finder reveals through the injected action")
    model.openApp(); model.openSettings()
    check(openedApp == 1 && openedSettings == 1, "the footer reaches the app and Settings")
    model.panelClosed()
    check(model.phase == .idle, "closing clears a finished batch")

    // With the panel open nobody needs a notification; "convert as soon as dropped" runs without a click.
    model.panelOpened()
    Defaults[.convertOnMenuBarDrop] = true
    model.add([f.file("Memo.wav")])
    _ = complete(10) { await model.running?.value }
    check(model.phase == .finished && f.queue.enqueued.count == 2 && f.queue.enqueued[1].plan.request.target == "mp3", "dropping converts at once when the setting is on")
    check(f.notifier.posted.count == 1, "no notification while the panel is open")
    check(model.recents.count == 2, "and the recent list refreshed")
}

// MARK: - Offscreen render

@MainActor
private func renderPanel(_ model: PanelModel, dark: Bool) -> NSBitmapImageRep {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: PanelView(model: model).environment(\.colorScheme, dark ? .dark : .light))
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    host.layoutSubtreeIfNeeded()
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

private func pixel(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> NSColor {
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    return rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .magenta
}

private func isNear(_ c: NSColor, _ hex: String, tolerance: CGFloat = 0.04) -> Bool {
    let b = NSColor(hex: hex).usingColorSpace(.sRGB)!
    return abs(c.redComponent - b.redComponent) <= tolerance && abs(c.greenComponent - b.greenComponent) <= tolerance && abs(c.blueComponent - b.blueComponent) <= tolerance
}

@MainActor private func menuBarPanelRender() {
    let f = MenuBarFixture(); defer { f.cleanUp() }
    let width = SCMetrics.MenuBarPanel.width
    let model = PanelModel(converter: f.converter)

    // Empty: the small dashed drop area and the footer.
    let empty = renderPanel(model, dark: false)
    check(empty.size.width == width && empty.size.height > 140 && empty.size.height < 260, "an empty panel is 360 pt wide and short: \(empty.size)")
    check(isNear(pixel(empty, x: 4, y: 40), SCColor.card.light), "the panel is the card colour")

    // The mockup's panel: two files, Convert, the recent list.
    f.converter.recents.add([
        RecentConversion(sourceName: "Invoice 0412.docx", sourceFormat: "docx", output: URL(fileURLWithPath: "/tmp/Invoice 0412.pdf"), date: Date().addingTimeInterval(-600)),
        RecentConversion(sourceName: "Invoice 0412.docx", sourceFormat: "docx", output: URL(fileURLWithPath: "/tmp/Invoice 0412.pdf"), date: Date().addingTimeInterval(-120)),
    ])
    model.refreshRecents()
    model.add([f.file("Beach at golden hour.heic"), f.file("Screen recording 2026-10-22.mov")])
    let light = renderPanel(model, dark: false), dark = renderPanel(model, dark: true)
    check(light.size.width == width && light.size.height > 400 && light.size.height < 560, "a panel with two files and two recents: \(light.size)")
    check(light.size.height > empty.size.height, "files and recents make it taller")
    check(isNear(pixel(dark, x: 4, y: 40), SCColor.card.dark), "dark appearance uses the dark card")

    // The Convert button is a gradient from the image colour to the video colour (ux §3.4 item 4): find its row, then compare ends.
    let scan = stride(from: light.size.height * 0.30, to: light.size.height * 0.75, by: 1)
    var buttonY: CGFloat?
    for y in scan where pixel(light, x: 60, y: y).saturationComponent > 0.45 && pixel(light, x: width - 60, y: y).saturationComponent > 0.45
        && pixel(light, x: width / 2 - 100, y: y).saturationComponent > 0.45 { buttonY = y; break }
    check(buttonY != nil, "a saturated Convert button is drawn")
    if let y = buttonY {
        let left = pixel(light, x: 40, y: y), right = pixel(light, x: width - 40, y: y)
        check(abs(left.hueComponent - right.hueComponent) > 0.05 || abs(left.redComponent - right.redComponent) > 0.1, "its fill runs between the two target colours")
    }

    // Different batches look different: converting rows are not the ready rows.
    model.convert()
    _ = complete(10) { await model.running?.value }
    let done = renderPanel(model, dark: false)
    var differing = 0
    for y in stride(from: 0, to: min(light.size.height, done.size.height), by: 6) {
        for x in stride(from: 0, to: width, by: 6) where abs(pixel(light, x: x, y: y).greenComponent - pixel(done, x: x, y: y).greenComponent) > 0.1 { differing += 1 }
    }
    check(differing > 40, "the finished panel differs from the ready one")

    if let path = ProcessInfo.processInfo.environment["SUPERCONVERTER_RENDER_DIR"] {
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, rep) in [("menubar-empty", empty), ("menubar-ready", light), ("menubar-ready-dark", dark), ("menubar-done", done)] {
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        }
    }
}

/// ux §5.10–§5.11: the Settings switches are pluginkit elections, read every time (System Settings changes them too).
@MainActor private func menuBarSwitches() {
    let jpg = QuickAction.toJPG.bundleID, mp4 = QuickAction.toMP4.bundleID
    check(QuickActionSwitches.election(of: jpg, in: "+    \(jpg)(1.0.0)\n") == .use, "“+” is use")
    check(QuickActionSwitches.election(of: jpg, in: "-    \(jpg)(1.0.0)\n") == .ignore, "“-” is ignore")
    check(QuickActionSwitches.election(of: jpg, in: "     \(jpg)(1.0.0)\n") == .undecided, "a space is no election yet")
    check(QuickActionSwitches.election(of: jpg, in: "+    \(jpg)X(1.0.0)\n") == nil && QuickActionSwitches.election(of: jpg, in: "") == nil,
          "another extension, or none listed, is not this one")
    check(QuickActionSwitches.election(of: jpg, in: "+    \(mp4)(1.0.0)\n-    \(jpg)(1.0.0)\t3914A373\t2026-10-29\t/A.app\n") == .ignore,
          "the line for this id, verbose columns and all")

    let fixture = MenuBarFixture(); defer { fixture.cleanUp() }
    let previousTools = Services.tools
    defer { Services.tools = previousTools }
    let pluginkit = FakePluginKit([.convertWith: "+", .toJPG: "+", .toPNG: "+", .toPDF: "-", .toMP4: " ", .toMP3: "-"])
    Services.tools = pluginkit
    MenuBarKitModule.install()
    let menuBar: MenuBarPresenting = Services.menuBar
    func rows() -> [QuickActionSwitch] { (try? complete(10) { await menuBar.quickActionSwitches() }?.get()) ?? [] }
    func set(_ target: FormatID, _ on: Bool) -> QuickActionSwitch? { (try? complete(10) { await menuBar.setQuickAction(target, on: on) }?.get()) ?? nil }

    let first = rows()
    check(first.map(\.target) == ["jpg", "png", "pdf", "mp4", "mp3"], "the five one-step actions, in menu order: \(first.map(\.target))")
    check(first.map(\.isOn) == [true, true, false, false, false], "each as pluginkit has it: \(first.map(\.isOn))")
    check(first.map(\.title) == ["Convert to JPG", "Convert to PNG", "Convert to PDF", "Convert to MP4", "Convert to MP3"], "titled as in Finder")
    check(first.map(\.takes) == ["Images", "Images", "Documents, images, slides, sheets and e-books", "Videos", "Audio and videos"], "and what each takes (ux §5.10)")
    let oneStep: [QuickAction] = [.toJPG, .toPNG, .toPDF, .toMP4, .toMP3]
    check(pluginkit.takeRuns() == oneStep.map { ["-m", "-i", $0.bundleID] }, "one `pluginkit -m -i <id>` per action, nothing else")

    check(set("mp4", true)?.isOn == true, "switching MP4 on answers on")
    check(pluginkit.takeRuns() == [["-e", "use", "-i", mp4], ["-m", "-i", mp4]], "`pluginkit -e use -i <id>`, then a read back")
    check(pluginkit[.toMP4] == "+", "and macOS has it on")
    check(set("jpg", false)?.isOn == false && pluginkit.takeRuns() == [["-e", "ignore", "-i", jpg], ["-m", "-i", jpg]] && pluginkit[.toJPG] == "-",
          "switching JPG off is `pluginkit -e ignore -i <id>`")

    // Switched off in System Settings › Extensions behind the app's back: the next read says so.
    pluginkit[.toPNG] = "-"
    check(rows().first { $0.target == "png" }?.isOn == false, "PNG turned off in System Settings reads as off")
    pluginkit[.toMP3] = nil
    check(rows().first { $0.target == "mp3" }.map { $0.isOn == nil } == true, "an extension macOS doesn’t list has no state")
    _ = pluginkit.takeRuns()

    pluginkit.electionsFail = true
    check(set("pdf", true)?.isOn == false && pluginkit[.toPDF] == "-", "a switch macOS refuses answers what macOS still has")
    pluginkit.electionsFail = false
    _ = pluginkit.takeRuns()
    check(set("gif", true) == nil && pluginkit.takeRuns().isEmpty, "no action makes GIF: nothing runs")
    check(pluginkit[.convertWith] == "+", "“Convert with Super Converter…” is never switched")
}

/// ux §5.10: at first launch JPG, PNG and PDF are switched on and MP4 and MP3 off, once, keeping the person's own choices.
@MainActor private func menuBarFirstLaunch() {
    let fixture = MenuBarFixture(); defer { fixture.cleanUp() }
    let unlisted = FakePluginKit([.toJPG: " ", .toPNG: " ", .toPDF: " ", .toMP4: " "])
    let notYet = (try? complete(10) { await QuickActionSwitches(tools: unlisted).electAtFirstLaunch() }?.get()) ?? true
    check(!notYet && !Defaults[.quickActionsElected], "with an extension not listed yet, nothing is decided")
    check(!unlisted.takeRuns().contains { $0.first == "-e" } && unlisted[.toJPG] == " ", "and nothing is switched")

    let pluginkit = FakePluginKit([.convertWith: " ", .toJPG: " ", .toPNG: "-", .toPDF: " ", .toMP4: " ", .toMP3: "+"])
    let done = (try? complete(10) { await QuickActionSwitches(tools: pluginkit).electAtFirstLaunch() }?.get()) ?? false
    check(done && Defaults[.quickActionsElected], "the elections are made once every extension is listed")
    let elections = pluginkit.takeRuns().filter { $0.first == "-e" }
    check(elections == [["-e", "use", "-i", QuickAction.toJPG.bundleID], ["-e", "use", "-i", QuickAction.toPDF.bundleID],
                        ["-e", "ignore", "-i", QuickAction.toMP4.bundleID]], "JPG and PDF on, MP4 off: \(elections)")
    check(pluginkit[.toPNG] == "-" && pluginkit[.toMP3] == "+", "PNG and MP3, already chosen in System Settings, are left alone")
    check(pluginkit[.convertWith] == " ", "“Convert with Super Converter…” is left as macOS has it")
    _ = complete(10) { await QuickActionSwitches(tools: pluginkit).electAtFirstLaunch() }
    check(pluginkit.takeRuns().isEmpty, "the second launch runs nothing")
}
#else
func registerMenuBarKitTests() {}
#endif
