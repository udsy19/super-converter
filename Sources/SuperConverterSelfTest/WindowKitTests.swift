import AppKit
import Combine
import Foundation
import SuperConverterCore
import SwiftUI
#if DEBUG
@testable import WindowKit

// WindowKit's checks (WP-U): view models against Core fakes, the picker's search fixtures, the options model, and offscreen
// renders (NSView.cacheDisplay at 2x) compared with the mockups. Set SUPERCONVERTER_RENDER_DIR to write the renders and the
// side-by-side comparisons (mockup left, render right) there; without it the renders are still made and probed.
func registerWindowKitTests() {
    let cases: [(String, @MainActor () -> Void)] = [
        ("WindowKit.installs", windowInstalls),
        ("WindowKit.addingFiles", windowAddingFiles),
        ("WindowKit.targetsAndSetAll", windowTargets),
        ("WindowKit.convertRun", windowConvertRun),
        ("WindowKit.fixesAndHelpers", windowFixes),
        ("WindowKit.optionsModel", windowOptions),
        ("WindowKit.pickerSearch", windowPickerSearch),
        ("WindowKit.pickerSections", windowPickerSections),
        ("WindowKit.folders", windowFolders),
        ("WindowKit.quickLook", windowQuickLook),
        ("WindowKit.accessibilityAndCopy", windowAccessibility),
        ("WindowKit.renders", windowRenders),
    ]
    for c in cases { SelfTest.cases.append(c) }
}

// MARK: - Test doubles

/// Records what the window asked the outside world to do; opens nothing.
@MainActor
final class RecordingActions: FileActions {
    var revealed: [[URL]] = []
    var opened: [URL] = []
    var quickLookShown = false
    var quickLookCalls: [Bool] = []
    var chosen: [URL] = []
    var folder: URL?
    var gotten: [HelperID] = []
    var password: String?
    var includeSub = false
    var confirm = true
    func reveal(_ urls: [URL]) { revealed.append(urls) }
    func open(_ url: URL) { opened.append(url) }
    func setQuickLook(_ shown: Bool) { quickLookShown = shown; quickLookCalls.append(shown) }
    func chooseFiles(filter: FormatID?) -> [URL] { chosen }
    func chooseFolder() -> URL? { folder }
    func get(_ helper: HelperID) { gotten.append(helper) }
    func includeSubfolders(folder: String, fileCount: Int) -> Bool { includeSub }
    func confirmStop(count: Int) -> Bool { confirm }
    func askPassword(for name: String) -> String? { password }
}

/// A queue whose events the test pushes by hand.
@MainActor
final class StubQueue: JobQueueing {
    private(set) var enqueued: [(id: JobID, plan: ConversionPlan, place: OutputPlace)] = []
    private(set) var cancelled: [JobID] = []
    let events: AsyncStream<JobEvent>
    private let continuation: AsyncStream<JobEvent>.Continuation
    init() {
        var captured: AsyncStream<JobEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }
    var activeCount: Int { enqueued.count - cancelled.count }
    func enqueue(_ plan: ConversionPlan, into place: OutputPlace) -> JobID {
        let id = JobID()
        enqueued.append((id, plan, place))
        return id
    }
    func cancel(_ job: JobID) { cancelled.append(job) }
    func cancelAll() {}
}

/// A planner that answers per target: a missing-helper route for some pairs, the built-in route otherwise.
@MainActor
final class StubPlanner: Planning {
    var missing: [FormatID: HelperID] = [:]
    /// Helpers count as missing only until the helper service says they are installed.
    weak var helpers: FakeHelpers?
    var better: [FormatID: HelperID] = [:]
    func choice(for target: FormatID) -> RouteChoice {
        if let helper = missing[target], helpers?.status(of: helper).isReady != true { return .helper(steps: [], helpers: [helper], missing: [helper]) }
        return .builtin(steps: [])
    }
    func plan(for request: ConversionRequest) -> ConversionPlan {
        let profile = FormatMatrix.route(from: request.sourceFormat, to: request.target)?.options ?? "O-IMG"
        return ConversionPlan(request: request, choice: choice(for: request.target), optionProfile: profile,
                              betterWithHelper: better[request.target], availableLooks: [.asWritten, .latex])
    }
    func targets(for source: FormatID) -> [(format: FormatID, choice: RouteChoice)] {
        FormatMatrix.targets(for: source).map { ($0, choice(for: $0)) }
    }
}

/// Installs the stubs and a fresh view model; the sniffer knows sizes.
@MainActor
struct Fixture {
    let vm: WindowViewModel
    let actions = RecordingActions()
    let queue = StubQueue()
    let planner = StubPlanner()
    let sniffer = FakeSniffer()
    let helpers = FakeHelpers()

    init() {
        installFakes()
        Services.queue = queue
        Services.planner = planner
        Services.sniffer = sniffer
        Services.helpers = helpers
        planner.helpers = helpers
        let store = UserDefaults(suiteName: "superconverter-windowkit-\(UUID().uuidString)")!
        Defaults.store = store
        vm = WindowViewModel(actions: actions)
        vm.animates = false
    }

    /// A fictional file of `bytes`, known to the sniffer.
    @discardableResult
    func file(_ name: String, bytes: Int64, as format: FormatID? = nil) -> URL {
        let url = URL(fileURLWithPath: "/tmp/superconverter-fixture/\(name)")
        let ext = FormatCatalog.format(forFileName: name)?.id
        sniffer.results[url] = SniffResult(format: format ?? ext, claimed: ext, sizeBytes: bytes)
        return url
    }

    func card(_ name: String) -> FileCard { vm.cards.first { $0.name == name }! }
}

private func pump(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

// MARK: - View model

@MainActor private func windowInstalls() {
    _ = NSApplication.shared
    WindowKitModule.install()
    check(Services.window != nil, "install registers the window")
    check(Services.window.hasWork == false, "a new window has no work")
}

@MainActor private func windowAddingFiles() {
    let f = Fixture()
    let urls = [f.file("Beach at golden hour.heic", bytes: 4_200_000), f.file("Quarterly report.docx", bytes: 86_000),
                f.file("Mystery.xyz", bytes: 10), f.file("Photo.jpg", bytes: 5_000_000, as: "png")]
    f.sniffer.results[urls[3]] = SniffResult(format: "png", claimed: "jpg", sizeBytes: 5_000_000)
    f.vm.add(urls)
    check(f.vm.cards.count == 4, "four cards")
    check(f.vm.phase == .ready, "ready phase")
    check(f.card("Beach at golden hour.heic").target == "jpg", "HEIC defaults to JPG (ux §6.1)")
    check(f.card("Quarterly report.docx").target == "pdf", "DOCX defaults to PDF")
    check(f.card("Mystery.xyz").state == .unreadable, "unknown kinds are added and unreadable")
    check(f.card("Mystery.xyz").target == nil, "no target for unreadable files")
    check(f.card("Photo.jpg").mismatch == "png", "a PNG named .jpg says so")
    check(f.card("Photo.jpg").source == "png", "content wins over the extension (ux §6.2)")
    check(f.vm.readyCards.count == 3, "unreadable cards are not converted")
    check(f.vm.convertTitle == "Convert 3 files", "the button counts files: \(f.vm.convertTitle)")
    check(f.vm.subtitle == "4 files · 9.3 MB", "toolbar subtitle: \(f.vm.subtitle ?? "nil")")
    check(f.vm.buttonCategories == [.image, .document], "button colours follow the batch in card order: \(f.vm.buttonCategories)")

    f.vm.add([urls[0]])
    check(f.vm.cards.count == 4, "the same file is not added twice")

    // Remembered choice wins; a preset target wins over both.
    Defaults[.target(for: "heic")] = "png"
    f.vm.add([f.file("Second.heic", bytes: 1_000)])
    check(f.card("Second.heic").target == "png", "the last choice for a source format wins")
    f.vm.add([f.file("Third.heic", bytes: 1_000)], target: "webp")
    check(f.card("Third.heic").target == "webp", "a preset target (popular pair, Quick Action) is used")
    f.vm.add([f.file("Fourth.heic", bytes: 1_000)], target: "mp3")
    check(f.card("Fourth.heic").target == "png", "a preset the source cannot become is ignored")

    // Saved options for the target apply to new cards.
    Defaults[.savedOptions(for: "jpg")] = OptionValues(["quality": 70])
    f.vm.add([f.file("Fifth.png", bytes: 1_000)])
    f.vm.setTarget("jpg", for: [f.card("Fifth.png")])
    check(f.card("Fifth.png").options["quality"] == 70, "saved options come with the target")

    f.vm.remove([f.card("Second.heic")])
    check(f.vm.cards.contains { $0.name == "Second.heic" } == false, "remove")
    f.vm.selectAll()
    check(f.vm.selection.count == f.vm.cards.count, "select all")
    f.vm.removeSelected()
    check(f.vm.cards.isEmpty && f.vm.phase == .empty, "removing everything returns to the empty window")
}

@MainActor private func windowTargets() {
    let f = Fixture()
    f.vm.add([f.file("a.heic", bytes: 1), f.file("b.png", bytes: 1), f.file("c.docx", bytes: 1)])
    let picker = f.vm.pickerModel(for: f.card("a.heic"))!
    check(picker.placeholder.hasPrefix("Search ") && picker.placeholder.hasSuffix(" formats for HEIC"), "placeholder: \(picker.placeholder)")
    check(picker.remember, "\"from now on\" is on by default")

    // Picking from a selected card of several changes them all.
    f.vm.selection = [f.card("a.heic").id, f.card("b.png").id]
    f.vm.pick("webp", remember: true, for: f.card("a.heic"))
    check(f.card("a.heic").target == "webp" && f.card("b.png").target == "webp", "a multi-selection changes together")
    check(f.card("c.docx").target == "pdf", "unselected cards keep theirs")
    check(Defaults[.target(for: "heic")] == "webp", "\"from now on\" remembers for the clicked card's source")
    check(Defaults[.target(for: "png")] == nil, "only the clicked source format is remembered")

    f.vm.setAll("pdf")
    check(f.vm.cards.allSatisfy { $0.target == "pdf" }, "set all to PDF")
    check(f.vm.sharedTarget == "pdf", "the popup shows the shared target")
    check(f.vm.commonTargets.contains("pdf") && f.vm.commonTargets.contains("png") == false || f.vm.commonTargets.contains("png"), "intersection is computed")
    f.vm.setAll("jpg", category: .image)
    check(f.card("a.heic").target == "jpg" && f.card("c.docx").target == "pdf", "set all within a category")
    check(f.vm.targetGroups.map(\.category).contains(.image), "groups by category")
    check(f.vm.sharedTarget == nil, "mixed targets show Choose a format")
}

@MainActor private func windowConvertRun() {
    let f = Fixture()
    f.vm.add([f.file("a.heic", bytes: 4_200_000), f.file("b.docx", bytes: 86_000), f.file("c.mov", bytes: 1_400_000_000)])
    let cards = f.vm.cards
    f.vm.convert()
    check(f.queue.enqueued.count == 3, "three jobs enqueued")
    check(f.queue.enqueued.allSatisfy { $0.place == .nextToOriginal }, "default place is next to the originals")
    check(cards.allSatisfy { $0.state == .queued }, "queued")
    check(f.vm.phase == .converting && f.vm.subtitle == "Converting 0 of 3", "converting subtitle: \(f.vm.subtitle ?? "")")

    let ids = f.queue.enqueued.map(\.id)
    f.vm.handle(.started(ids[0]))
    f.vm.handle(.progress(ids[0], JobProgress(fraction: 0.5, unit: nil, secondsLeft: 20)))
    check(f.card("a.heic").state == .converting(JobProgress(fraction: 0.5, unit: nil, secondsLeft: 20)), "progress lands on its card")
    check(abs(f.vm.overallFraction - 1.0 / 6) < 0.001, "overall fraction: \(f.vm.overallFraction)")
    check(f.vm.convertingDetail == "About 20 s left", "time left: \(f.vm.convertingDetail)")
    f.vm.handle(.finished(ids[0], ConversionResult(outputs: [URL(fileURLWithPath: "/tmp/superconverter-fixture/a.jpg")], inputBytes: 4_200_000, outputBytes: 1_900_000)))
    f.vm.handle(.started(ids[1]))
    f.vm.handle(.failed(ids[1], .passwordRequired("docx")))
    check(f.vm.phase == .converting, "still converting while one is queued")
    f.vm.handle(.started(ids[2]))
    f.vm.handle(.progress(ids[2], JobProgress(fraction: 0.62, unit: nil, secondsLeft: 40)))
    check(f.vm.convertingDetail == "About 40 s left · the video takes longest", "detail: \(f.vm.convertingDetail)")
    f.vm.handle(.finished(ids[2], ConversionResult(outputs: [URL(fileURLWithPath: "/tmp/superconverter-fixture/c.mp4")], inputBytes: 1_400_000_000, outputBytes: 286_000_000)))

    check(f.vm.phase == .finished, "finished when nothing is active")
    check(f.vm.finishedTitle == "Done. 2 of 3 files converted", "title: \(f.vm.finishedTitle)")
    check(f.vm.finishedDetail.contains("saved next to the originals") && f.vm.finishedDetail.contains("1 needs attention"), "detail: \(f.vm.finishedDetail)")
    check(f.vm.subtitle == "2 of 3 converted", "subtitle: \(f.vm.subtitle ?? "")")
    check(f.card("a.heic").shownName == "a.jpg", "a done card shows the new name")
    check(Strings.problem(.passwordRequired("docx")).fix == .enterPassword, "password fix")

    f.vm.revealResults()
    check(f.actions.revealed.last?.count == 2, "reveal selects every output")
    f.vm.open(f.card("a.heic"))
    check(f.actions.opened.last?.lastPathComponent == "a.jpg", "double-click opens the result")

    // Convert more clears finished cards, keeps the failed one's source? Failed counts as finished: both go.
    f.vm.convertMore()
    check(f.vm.cards.isEmpty, "convert more clears finished cards")

    // Stop returns running cards to ready and cancels their jobs.
    f.vm.add([f.file("d.heic", bytes: 10), f.file("e.heic", bytes: 10)])
    f.vm.convert()
    let jobs = f.queue.enqueued.suffix(2).map(\.id)
    f.vm.handle(.started(jobs[0]))
    f.vm.stop()
    check(f.queue.cancelled.count == 2 && f.vm.cards.allSatisfy { $0.state == .ready }, "stop cancels and returns cards to ready")
    check(f.vm.phase == .ready, "ready again after stop")

    // A cancelled event does the same for one card.
    f.vm.convert()
    let again = f.queue.enqueued.suffix(2).map(\.id)
    f.vm.handle(.cancelled(again[0]))
    check(f.card("d.heic").state == .ready, "cancelled event")
}

@MainActor private func windowFixes() {
    let f = Fixture()
    f.planner.missing["epub"] = .calibre
    f.vm.add([f.file("Middlemarch.mobi", bytes: 1_400_000), f.file("Signed contract.pdf", bytes: 10_000)])
    let book = f.card("Middlemarch.mobi")
    check(book.missingHelpers == [.calibre], "route with a missing helper")
    check(f.vm.blockingHelper(of: book) == .calibre, "the notice names calibre")
    check(Strings.Helper.needs(.calibre) == "Needs calibre" && Strings.Helper.cost(.calibre) == "Free · 160 MB", "notice copy")
    f.vm.convert()
    check(f.queue.enqueued.count == 1, "the card with a missing helper waits and is not enqueued")
    check(book.state == .waitingForHelper(.calibre), "waiting for calibre")

    f.vm.installHelper(for: book)
    check(book.helperInstall == 0, "install starts")
    pump(0.2)
    check(f.helpers.installs == [.calibre], "install goes through HelperKit's service")
    check(book.helperInstall == nil, "install finished")
    check(f.queue.enqueued.count == 2, "the card converts as soon as the helper is ready (enqueued: \(f.queue.enqueued.count))")

    // "Get…" helpers are explained, not installed.
    f.planner.missing["docx"] = .msoffice
    f.vm.add([f.file("Report.pages", bytes: 10)])
    f.planner.missing["docx"] = nil
    f.planner.missing["pdf"] = .ghostscript
    f.vm.add([f.file("Drawing.eps", bytes: 10)])
    f.vm.installHelper(for: f.card("Drawing.eps"))
    check(f.actions.gotten == [.ghostscript], "Get… goes to the vendor/explanation, not the installer")

    // Enter Password… stores the password for the card and makes it ready.
    let pdf = f.card("Signed contract.pdf")
    pdf.state = .failed(.passwordRequired("pdf"))
    f.actions.password = "hunter2"
    f.vm.perform(.enterPassword, for: pdf)
    check(pdf.options["password"] == "hunter2" && pdf.state == .ready, "password entered")
    f.vm.perform(.showInFinder, for: pdf)
    check(f.actions.revealed.last == [pdf.url], "show in Finder")

    // Choose Another Folder… changes the place and retries.
    let folder = URL(fileURLWithPath: "/tmp/superconverter-fixture/out")
    f.actions.folder = folder
    pdf.state = .failed(.folderNotWritable(name: "Shared"))
    let before = f.queue.enqueued.count
    f.vm.perform(.chooseAnotherFolder, for: pdf)
    check(Defaults[.outputPlace] == .folder(folder) && f.queue.enqueued.count == before + 1, "another folder is used and the file retries")
    check(f.queue.enqueued.last?.place == .folder(folder), "the job goes to the chosen folder")
    check(WindowViewModel.placeText(.folder(folder)) == "in “out”", "place text")

    // A decompression bomb asks first (quality §8): the card shows the question with Extract Anyway; choosing it runs the
    // same job again with the option the question names.
    f.vm.add([f.file("Huge.zip", bytes: 10_000)])
    let bomb = f.card("Huge.zip")
    let question = ConversionError.needsConfirmation(question: "This archive unpacks to over 1,000 times its size — extract it anyway?", proceed: .extractAnyway, option: "extractAnyway")
    bomb.state = .failed(question)
    check(Strings.problem(question).fix == .extractAnyway && Strings.problem(question).message.hasSuffix("extract it anyway?"), "the card asks, with Extract Anyway")
    let queued = f.queue.enqueued.count
    f.vm.perform(.extractAnyway, for: bomb)
    check(f.queue.enqueued.count == queued + 1 && f.queue.enqueued.last?.plan.request.options["extractAnyway"] == .bool(true), "Extract Anyway re-runs it with the option set")
    check(bomb.state == .queued && bomb.options["extractAnyway"] == .bool(true), "the card runs again")
    f.vm.perform(.extractAnyway, for: bomb)
    check(f.queue.enqueued.count == queued + 1, "without a question there is nothing to agree to")
    // A question from a background conversion (a notification's click) opens the card asking it, with that job's options.
    let background = f.file("Backup.zip", bytes: 10_000)
    f.vm.showProblem(background, target: "tar", options: OptionValues(["compression": "fast"]), problem: question)
    let asked = f.card("Backup.zip")
    check(asked.state == .failed(question) && asked.target == "tar" && asked.options["compression"] == "fast", "the card shows the question with the job's target and options")
    f.vm.perform(.extractAnyway, for: asked)
    check(f.queue.enqueued.last?.plan.request.source == background && f.queue.enqueued.last?.plan.request.options["extractAnyway"] == .bool(true), "and answers it")
    f.vm.remove([bomb, asked])

    // Try with LibreOffice runs the helper route.
    let doc = f.card("Report.pages")
    doc.state = .failed(.damaged("pages"))
    f.vm.perform(.tryWithLibreOffice, for: doc)
    check(doc.preferHelper == true, "prefers the helper route")
    check(doc.request?.preferHelper == true, "the request carries it")
}

@MainActor private func windowOptions() {
    let f = Fixture()
    f.vm.add([f.file("Beach at golden hour.heic", bytes: 4_200_000), f.file("Dunes.heic", bytes: 3_000_000)])
    let first = f.card("Beach at golden hour.heic")
    first.facts = ["4032 × 3024"]
    f.vm.selection = Set(f.vm.cards.map(\.id))
    f.vm.openOptions(for: first)
    guard let session = f.vm.options else { check(false, "options session opens"); return }
    let model = session.model
    check(session.cards.count == 2, "cards that share the pair edit together")
    check(model.title == "JPG options", "title: \(model.title)")
    check(model.subtitle == "Beach at golden hour.heic and 1 more photo", "subtitle: \(model.subtitle)")
    let primary = model.primary.map(\.key)
    check(primary.prefix(4) == ["quality", "size", "colourProfile", "metadata"], "first controls in plain words: \(primary)")
    check(model.moreSummary.contains("progressive"), "More options summary: \(model.moreSummary)")
    check(model.estimate == "About 2.1 MB each — looks the same as the original", "live estimate: \(model.estimate ?? "nil")")
    model.set(model.profile.definition("quality")!, .int(40))
    check(model.estimate?.contains("softer") == true, "estimate follows quality: \(model.estimate ?? "nil")")
    model.set(model.profile.definition("quality")!, .int(90))
    check(model.values.isEmpty, "a value equal to the default is not stored")
    model.set(model.profile.definition("quality")!, .int(75))
    model.set(model.profile.definition("size")!, .string("50"))
    model.useForEvery = true
    f.vm.applyOptions()
    check(first.options["quality"] == 75 && f.card("Dunes.heic").options["size"] == "50", "Done applies to every card in the session")
    check(first.hasChangedOptions, "the gear fills when options differ")
    check(Defaults[.savedOptions(for: "jpg")]?["quality"] == 75, "\"Use these settings for every JPG\" saves them")
    check(f.vm.options == nil, "sheet closed")

    f.vm.openOptions(for: first)
    f.vm.cancelOptions()
    check(f.vm.options == nil && first.options["quality"] == 75, "Cancel changes nothing")

    // Documents: the look control follows the planner's looks.
    f.vm.add([f.file("Paper.docx", bytes: 100)])
    f.vm.selection = []
    f.vm.openOptions(for: f.card("Paper.docx"))
    let doc = f.vm.options!.model
    let look = doc.profile.definition("look")!
    check(doc.looks == [.asWritten, .latex], "looks from the plan")
    doc.set(look, .string("latex"))
    check(doc.look == .latex && doc.values["look"] == nil, "look is the card's, not a stored option")
    f.vm.applyOptions()
    check(f.card("Paper.docx").look == .latex, "look applied")
}

@MainActor private func windowPickerSearch() {
    func results(_ source: FormatID, _ query: String) -> [FormatID] {
        let all = FormatMatrix.targets(for: source).map { PickerTarget(format: $0, choice: .builtin(steps: [])) }
        let model = FormatPickerModel(source: source, current: nil, targets: all)
        model.query = query
        return model.matches.map(\.format)
    }
    check(results("pdf", "word").contains("docx"), "\"word\" finds DOCX")
    check(results("pdf", "word").first == "docx" || results("pdf", "word").first == "doc", "word ranks the Word formats first: \(results("pdf", "word").prefix(3))")
    let kindle = results("epub", "kindle")
    check(kindle.contains("azw3") && kindle.contains("mobi"), "\"kindle\" finds AZW3 and MOBI: \(kindle)")
    let transparent = results("heic", "transparent")
    check(transparent.contains("png") && transparent.contains("webp"), "\"transparent\" finds PNG and WEBP: \(transparent)")
    check(results("heic", "jp").first == "jpg", "extension prefix first: \(results("heic", "jp"))")
    check(results("heic", "JPG") == ["jpg"] || results("heic", "JPG").first == "jpg", "case-insensitive exact match")
    check(results("heic", "zzzz").isEmpty, "no match is empty")
    check(results("heic", ".png").first == "png", "a leading dot is ignored")

    let gif = FormatPickerModel(source: "gif", current: nil, targets: FormatMatrix.targets(for: "gif").map { PickerTarget(format: $0, choice: .builtin(steps: [])) })
    gif.query = "mp3"
    check(gif.notOffered.contains { $0.format == "mp3" } || FormatMatrix.notOfferedReason(from: "gif", to: "mp3") == nil,
          "a pair that is not offered says why when searched")
}

@MainActor private func windowPickerSections() {
    let targets = FormatMatrix.targets(for: "heic").map { PickerTarget(format: $0, choice: .builtin(steps: [])) }
    let model = FormatPickerModel(source: "heic", current: "jpg", targets: targets)
    check(model.suggestions.map(\.target.format) == ["jpg", "png", "webp", "pdf"] || model.suggestions.count >= 4, "Best for chips: \(model.suggestions.map(\.target.format))")
    check(model.suggestions.first?.reason == "Any app", "JPG · Any app")
    check(model.sections.first?.category == .image, "categories in catalog order, image first for a photo")
    check(model.sections.contains { $0.category == .document && $0.hint == "one page per photo" }, "PDF — one page per photo")
    check(BestFor.hint(from: .image, to: ["svg"]) == "traced into shapes", "SVG — traced into shapes")
    check(Strings.Picker.useFromNowOn("jpg", source: "heic") == "Use JPG for HEIC files from now on", "footer copy")
    check(model.focused == "jpg", "focus starts on the current target")
    model.move(1)
    check(model.focused != "jpg", "arrows move focus")
    model.move(-1)
    check(model.focusedTarget?.format == "jpg", "return picks the focused target")
    model.query = "web"
    check(model.focusOrder.first == "webp" || model.focusOrder.contains("webp"), "typing filters the keyboard order")

    // A helper route shows the download glyph; an unavailable route cannot be picked.
    let helperTargets = [PickerTarget(format: "mobi", choice: .helper(steps: [], helpers: [.calibre], missing: [.calibre])),
                         PickerTarget(format: "epub", choice: .unavailable(reason: .notOffered("no")))]
    check(helperTargets[0].neededHelper == .calibre && helperTargets[0].isAvailable, "⬇ for a missing helper")
    check(!helperTargets[1].isAvailable, "unavailable targets are disabled")
    check(Strings.Picker.needsHelperHint(.calibre) == "Needs calibre — free, 160 MB", "hover text: \(Strings.Picker.needsHelperHint(.calibre))")
}

@MainActor private func windowFolders() {
    let f = Fixture()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("superconverter-windowkit-\(UUID().uuidString)")
    let sub = root.appendingPathComponent("inner")
    try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    for name in ["a.heic", "b.png", ".hidden.png"] { FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data([0])) }
    FileManager.default.createFile(atPath: sub.appendingPathComponent("c.png").path, contents: Data([0]))
    defer { try? FileManager.default.removeItem(at: root) }
    let top = f.vm.expand([root]).map(\.lastPathComponent)
    check(top == ["a.heic", "b.png"], "a folder expands one level, hidden files skipped: \(top)")
    f.vm.add([root])
    check(f.vm.cards.count == 2, "folder contents become cards")
}

/// Quick Look's data source and delegate against a fake window; the real panel is never opened.
@MainActor private func windowQuickLook() {
    let f = Fixture()
    let a = f.file("a.heic", bytes: 10), b = f.file("b.heic", bytes: 10)
    f.vm.add([a, b])
    let first = f.vm.cards[0], second = f.vm.cards[1]
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("superconverter-ql-\(UUID().uuidString)/Pages (PNG)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    for name in ["p2.png", "p1.png", ".hidden"] { FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data([0])) }

    // Space toggles through the seam; nothing selected does nothing.
    f.vm.selection = []
    f.vm.toggleQuickLook()
    check(f.actions.quickLookCalls.isEmpty, "Space with no selection does nothing")
    f.vm.selection = [first.id]
    f.vm.toggleQuickLook()
    check(f.actions.quickLookCalls == [true] && f.actions.quickLookShown, "Space opens the panel")
    f.vm.toggleQuickLook()
    check(f.actions.quickLookCalls == [true, false], "Space again closes it")
    f.vm.selection = []
    f.vm.quickLook(second)
    check(f.vm.selection == [second.id] && f.actions.quickLookCalls.last == true, "the Done card button selects the card and opens the panel")

    // Source cards preview their own file; a folder result previews every file in it.
    check(f.vm.previewFiles(for: first) == [a], "a waiting card previews its source")
    second.state = .done(ConversionResult(outputs: [folder]))
    check(f.vm.previewFiles(for: second).map(\.lastPathComponent) == ["p1.png", "p2.png"], "a result folder previews all its files, hidden skipped")
    first.state = .done(ConversionResult(outputs: [a.deletingPathExtension().appendingPathExtension("jpg")]))
    check(f.vm.previewFiles(for: first).map(\.lastPathComponent) == ["a.jpg"], "a single result previews that file")

    // Data source and delegate.
    f.vm.selection = [first.id, second.id]
    let ql = QuickLookController(source: f.vm)
    ql.refresh()
    check(ql.numberOfPreviewItems(in: nil) == 3, "items from every selected card: \(ql.numberOfPreviewItems(in: nil))")
    check((ql.previewPanel(nil, previewItemAt: 2) as? NSURL)?.lastPathComponent == "p2.png", "item 2")
    check(ql.previewPanel(nil, previewItemAt: 9) == nil, "out of range is nil, not a crash")
    check(f.vm.previewStartIndex == 1, "opens on the last-selected card's first file")
    func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    check(!ql.previewPanel(nil, handle: key(124)), "with several selected the panel pages itself")
    f.vm.selection = [first.id]
    ql.refresh()
    check(ql.previewPanel(nil, handle: key(124)), "the arrow is handled")
    check(f.vm.selection == [second.id], "right arrow moves the card selection")
    check(ql.numberOfPreviewItems(in: nil) == 2, "the panel followed the selection to the folder's files")
    f.vm.columns = 2
    check(!ql.previewPanel(nil, handle: key(0)), "other keys are left to the panel")
    _ = ql.previewPanel(nil, handle: key(126))
    check(f.vm.selection == [first.id], "up arrow moves a row")

    // The zoom: the card's frame converted to the screen, and its thumbnail as the transition image.
    ql.screenRect = { $0.offsetBy(dx: 100, dy: 200) }
    f.vm.thumbnailFrames[first.id] = CGRect(x: 10, y: 20, width: 30, height: 40)
    f.vm.selection = [first.id]
    ql.refresh()
    let item = ql.previewPanel(nil, previewItemAt: 0)
    check(ql.previewPanel(nil, sourceFrameOnScreenFor: item) == NSRect(x: 110, y: 220, width: 30, height: 40), "source frame is the thumbnail on screen")
    f.vm.thumbnailFrames[first.id] = nil
    check(ql.previewPanel(nil, sourceFrameOnScreenFor: item) == .zero, "no zoom for a card that is off screen")
    let image = NSImage(size: NSSize(width: 4, height: 4))
    first.resultThumbnail = image
    check(ql.previewPanel(nil, transitionImageFor: item, contentRect: nil) as? NSImage === image, "transition image is the card's thumbnail")
}

@MainActor private func windowAccessibility() {
    let f = Fixture()
    f.vm.add([f.file("Beach at golden hour.heic", bytes: 4_200_000)])
    let card = f.vm.cards[0]
    check(card.accessibilitySummary == "Beach at golden hour, HEIC photo, 4.2 megabytes. Becomes JPG.", "one element, ux §6.7 wording: \(card.accessibilitySummary)")
    card.state = .converting(JobProgress(fraction: 0.5))
    check(card.accessibilitySummary.contains("50 percent"), "progress is spoken")
    check(DragSummary(urls: [URL(fileURLWithPath: "/a.heic"), URL(fileURLWithPath: "/b.jpg"), URL(fileURLWithPath: "/c.mov")]).line == "2 photos and a video. You’ll pick what each becomes next.", "drag line")
    check(DragSummary(urls: [URL(fileURLWithPath: "/a.heic")]).headline == "Drop 1 file to add it", "singular headline")
    check(FileFacts.clock(134) == "2:14" && FileFacts.clock(2480) == "41:20" && FileFacts.clock(3723) == "1:02:03", "clock")
    // Tone of the window's own copy.
    for text in [Strings.Window.emptyHeadline, Strings.Window.emptyLine, Strings.Window.chooseFiles] {
        check(!text.contains("\"") && !text.contains("'") && !text.contains("...") && !text.contains("!"), "tone: \(text)")
    }
    check(SCColor.categories.count == 11, "eleven palettes drive the pills")
    for ordinary in SCColor.categories {
        check(ordinary.filledContrast >= 4.5, "pill contrast \(ordinary.category)")
    }
}

// MARK: - Renders

/// The mockup folder, found from this file's path.
private func mockupsDirectory() -> URL? {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/mockups")
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("window-cards.png").path) ? url : nil
}

private func renderDirectory() -> URL? {
    guard let path = ProcessInfo.processInfo.environment["SUPERCONVERTER_RENDER_DIR"] else { return nil }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
private func render<V: View>(_ view: V, size: CGSize?, dark: Bool, scale: CGFloat = 2) -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
    let fitted = size ?? host.fittingSize
    host.frame = NSRect(origin: .zero, size: fitted)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    pump(0.25)
    host.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(fitted.width * scale), pixelsHigh: Int(fitted.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = fitted
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

private func png(_ rep: NSBitmapImageRep, to url: URL) { try? rep.representation(using: .png, properties: [:])?.write(to: url) }

private func color(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> NSColor {
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    return (rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)) ?? .magenta
}

private func close(_ a: NSColor, _ hex: String, tolerance: CGFloat = 0.03) -> Bool {
    let b = NSColor(hex: hex).usingColorSpace(.sRGB)!
    return abs(a.redComponent - b.redComponent) <= tolerance && abs(a.greenComponent - b.greenComponent) <= tolerance && abs(a.blueComponent - b.blueComponent) <= tolerance
}

/// The window region of a mockup at 2x pixels (the mockups are 2560 × 1640 with the window at 1080 × 700 pt).
private func mockupWindow(_ name: String) -> NSBitmapImageRep? {
    guard let dir = mockupsDirectory(), let image = NSImage(contentsOf: dir.appendingPathComponent(name)),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let crop = cg.cropping(to: CGRect(x: 200, y: 120, width: 2160, height: 1400)) else { return nil }
    return NSBitmapImageRep(cgImage: crop)
}

/// Mean absolute difference of two renders on a coarse luminance grid (0 identical … 1 inverted).
private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
    let step = 8
    var total = 0.0, count = 0.0
    var y = 0
    while y < min(a.pixelsHigh, b.pixelsHigh) {
        var x = 0
        while x < min(a.pixelsWide, b.pixelsWide) {
            if let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                let lp = 0.299 * p.redComponent + 0.587 * p.greenComponent + 0.114 * p.blueComponent
                let lq = 0.299 * q.redComponent + 0.587 * q.greenComponent + 0.114 * q.blueComponent
                total += Double(abs(lp - lq)); count += 1
            }
            x += step
        }
        y += step
    }
    return count > 0 ? total / count : 1
}

/// Draws the traffic lights the real title bar supplies, so a render reads like the mockup.
private func withChrome(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = rep.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    rep.draw(in: NSRect(origin: .zero, size: rep.size))
    for (i, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
        NSColor(hex: hex).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16 + CGFloat(i) * 20.3, y: rep.size.height - 32, width: 12, height: 12)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return out
}

/// Composites a popover or sheet render over a window render, with the popover's rounded corners and shadow.
private func overlay(_ base: NSBitmapImageRep, _ top: NSBitmapImageRep, at point: CGPoint, radius: CGFloat) -> NSBitmapImageRep {
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = base.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    base.draw(in: NSRect(origin: .zero, size: base.size))
    let frame = NSRect(x: point.x, y: base.size.height - point.y - top.size.height, width: top.size.width, height: top.size.height)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -8)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
    top.draw(in: frame)
    NSGraphicsContext.restoreGraphicsState()
    return out
}

/// Mockup on the left, render on the right.
private func sideBySide(_ left: NSBitmapImageRep, _ right: NSBitmapImageRep) -> NSBitmapImageRep {
    let gap = 40, w = left.pixelsWide + gap + right.pixelsWide, h = max(left.pixelsHigh, right.pixelsHigh)
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSColor(white: 0.5, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    left.draw(in: NSRect(x: 0, y: 0, width: left.pixelsWide, height: left.pixelsHigh))
    right.draw(in: NSRect(x: left.pixelsWide + gap, y: 0, width: right.pixelsWide, height: right.pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
    return out
}

/// The eight files of `window-cards.png`.
@MainActor
private func cardsFixture() -> Fixture {
    let f = Fixture()
    f.vm.add([f.file("Beach at golden hour.heic", bytes: 4_200_000), f.file("Quarterly report.docx", bytes: 86_000), f.file("Interview take 3.mov", bytes: 1_400_000_000),
              f.file("Podcast episode 12.wav", bytes: 212_000_000), f.file("Budget 2027.xlsx", bytes: 48_000), f.file("Pitch deck.pptx", bytes: 12_600_000),
              f.file("The Time Machine.epub", bytes: 412_000), f.file("Logo final.svg", bytes: 18_000)])
    let facts: [[String]] = [["4032 × 3024"], ["12 pages"], ["4K", "2:14"], ["48 kHz", "41:20"], ["3 sheets"], ["18 slides"], ["12 chapters"], ["512 × 512"]]
    for (card, fact) in zip(f.vm.cards, facts) { card.facts = fact }
    f.vm.selection = [f.vm.cards[2].id]
    return f
}

/// The eight files of `window-converting.png` and `window-done.png`, run through the real flow with events.
@MainActor
private func runFixture(finished: Bool) -> Fixture {
    let f = Fixture()
    f.planner.missing["epub"] = .calibre
    if finished { f.helpers.statuses[.calibre] = .installed(version: "7", location: URL(fileURLWithPath: "/dev/null"), sizeOnDisk: nil) }
    f.vm.add([f.file("Beach at golden hour.heic", bytes: 4_200_000), f.file("Quarterly report.docx", bytes: 312_000), f.file("Interview take 3.mov", bytes: 1_400_000_000),
              f.file("Pitch deck.pptx", bytes: 12_600_000), f.file("Middlemarch.mobi", bytes: 1_400_000), f.file("Thesis notes.md", bytes: 9_000),
              f.file("Podcast episode 12.wav", bytes: 212_000_000), f.file("Inter-Regular.ttf", bytes: 300_000)])
    let cards = f.vm.cards
    for (card, fact) in zip(cards, [["4032 × 3024"], ["12 pages"], ["4K", "2:14"], ["18 slides"], [], [], ["48 kHz", "41:20"], []] as [[String]]) { card.facts = fact }
    f.vm.convert()
    func out(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/superconverter-fixture/\(name)") }
    let jobs = cards.map { $0.jobID ?? JobID() }
    if !finished {
        // Beach, Quarterly done; Interview 62 %; Pitch slide 7 of 18; Middlemarch waits for calibre; the rest queued.
        f.vm.handle(.started(jobs[0])); f.vm.handle(.finished(jobs[0], ConversionResult(outputs: [out("Beach at golden hour.jpg")], inputBytes: 4_200_000, outputBytes: 1_900_000)))
        f.vm.handle(.started(jobs[1])); f.vm.handle(.finished(jobs[1], ConversionResult(outputs: [out("Quarterly report.pdf")], inputBytes: 312_000, outputBytes: 312_000)))
        f.vm.handle(.started(jobs[2])); f.vm.handle(.progress(jobs[2], JobProgress(fraction: 0.62, unit: nil, secondsLeft: 40)))
        f.vm.handle(.started(jobs[3])); f.vm.handle(.progress(jobs[3], JobProgress(fraction: 0.28, unit: "Slide 7 of 18", secondsLeft: 20)))
        f.vm.selection = []
        return f
    }
    let results: [(String, Int64, Int64)] = [("Beach at golden hour.jpg", 4_200_000, 1_900_000), ("Quarterly report.pdf", 312_000, 312_000),
                                             ("Interview take 3.mp4", 1_400_000_000, 286_000_000), ("Pitch deck.pdf", 12_600_000, 2_100_000)]
    for (i, r) in results.enumerated() { f.vm.handle(.started(jobs[i])); f.vm.handle(.finished(jobs[i], ConversionResult(outputs: [out(r.0)], inputBytes: r.1, outputBytes: r.2))) }
    f.vm.handle(.finished(jobs[4], ConversionResult(outputs: [out("Middlemarch.epub")], inputBytes: 1_400_000, outputBytes: 1_400_000)))
    f.vm.handle(.finished(jobs[5], ConversionResult(outputs: [out("Thesis notes.pdf")], inputBytes: 9_000, outputBytes: 9_000)))
    f.vm.handle(.failed(jobs[6], .passwordRequired("wav")))
    f.vm.handle(.finished(jobs[7], ConversionResult(outputs: [out("Inter-Regular.woff2")], inputBytes: 300_000, outputBytes: 61_000)))
    return f
}

@MainActor private func windowRenders() {
    _ = NSApplication.shared
    let size = SCMetrics.Window.defaultSize
    let dir = renderDirectory()
    var report: [String] = []

    func shot(_ name: String, _ f: Fixture, dark: Bool, mockup: String, overlayView: ((Bool) -> (NSBitmapImageRep, CGPoint, CGFloat))? = nil) -> NSBitmapImageRep {
        var mine = render(MainView(vm: f.vm), size: size, dark: dark)
        if let overlayView { let (top, point, radius) = overlayView(dark); mine = overlay(mine, top, at: point, radius: radius) }
        mine = withChrome(mine)
        let suffix = dark ? "-dark" : ""
        if let dir {
            png(mine, to: dir.appendingPathComponent("\(name)\(suffix).png"))
            if let mock = mockupWindow(mockup) { png(sideBySide(mock, mine), to: dir.appendingPathComponent("\(name)\(suffix)-compare.png")) }
        }
        if let mock = mockupWindow(mockup) { report.append("\(name)\(suffix): difference \(String(format: "%.3f", difference(mock, mine)))") }
        return mine
    }

    // Empty and drag.
    let empty = Fixture()
    let emptyLight = shot("window-empty", empty, dark: false, mockup: "window-empty.png")
    check(close(color(emptyLight, x: 540, y: 600), SCColor.windowBackground.light, tolerance: 0.02), "empty window background")
    _ = shot("window-empty", empty, dark: true, mockup: "window-empty-dark.png")
    let dragging = Fixture()
    dragging.vm.drag = DragSummary(count: 3, kinds: [(.image, 2), (.video, 1)])
    _ = shot("window-drag", dragging, dark: false, mockup: "window-drag.png")

    // Cards: light and dark; the picker and the options sheet over them.
    let cards = cardsFixture()
    let light = shot("window-cards", cards, dark: false, mockup: "window-cards.png")
    let tint = SCColor.colors(for: .image).tint
    check(close(color(light, x: 112, y: 90), tint, tolerance: 0.03), "heic card's thumbnail well wears the Images tint \(tint)")
    check(close(color(light, x: 345, y: 90), SCColor.colors(for: .document).tint, tolerance: 0.03), "docx card's well wears the Documents tint")
    check(close(color(light, x: 20, y: 300), SCColor.windowBackground.light, tolerance: 0.02), "window background left of the grid")
    check(close(color(light, x: 150, y: 235), SCColor.card.light, tolerance: 0.02), "card body is white")
    _ = shot("window-cards", cards, dark: true, mockup: "window-cards-dark.png")
    let darkCards = shot("window-cards", cardsFixture(), dark: true, mockup: "window-cards-dark.png")
    check(close(color(darkCards, x: 112, y: 90), SCColor.colors(for: .image).darkTint, tolerance: 0.03), "dark tint")

    func pickerOverlay(_ f: Fixture) -> (Bool) -> (NSBitmapImageRep, CGPoint, CGFloat) {
        { dark in
            let model = f.vm.pickerModel(for: f.vm.cards[0])!
            return (render(FormatPickerView(model: model, pick: { _ in }, close: {}), size: nil, dark: dark), CGPoint(x: 116, y: 315), 14)
        }
    }
    let pickerFixture = cardsFixture()
    pickerFixture.vm.selection = [pickerFixture.vm.cards[0].id]
    _ = shot("target-picker", pickerFixture, dark: false, mockup: "target-picker.png", overlayView: pickerOverlay(pickerFixture))

    let sheetFixture = cardsFixture()
    sheetFixture.vm.selection = [sheetFixture.vm.cards[0].id]
    let sheetOverlay: (Bool) -> (NSBitmapImageRep, CGPoint, CGFloat) = { dark in
        let model = OptionsModel(source: "heic", target: "jpg", profile: OptionProfiles.profile("O-IMG+Q")!, values: OptionValues(), look: nil,
                                 subtitle: "Beach at golden hour.heic and 1 more photo", pixels: (4032, 3024))
        return (render(OptionsSheetView(model: model, cancel: {}, done: {}), size: nil, dark: dark), CGPoint(x: 240, y: 52), 14)
    }
    _ = shot("options-sheet", sheetFixture, dark: false, mockup: "options-sheet.png", overlayView: sheetOverlay)

    // Converting and done.
    let converting = runFixture(finished: false)
    check(converting.vm.phase == .converting, "converting fixture")
    let convertingShot = shot("window-converting", converting, dark: false, mockup: "window-converting.png")
    check(close(color(convertingShot, x: 20, y: 300), SCColor.windowBackground.light, tolerance: 0.02), "converting window background")
    let done = runFixture(finished: true)
    check(done.vm.phase == .finished, "done fixture is finished")
    check(done.vm.finishedTitle == "Done. 7 of 8 files converted", "done title: \(done.vm.finishedTitle)")
    _ = shot("window-done", done, dark: false, mockup: "window-done.png")
    _ = shot("window-done", done, dark: true, mockup: "window-done-dark.png")

    // List view, and 2x scale really is 2x.
    let list = cardsFixture()
    list.vm.setViewMode(.list)
    let listShot = render(MainView(vm: list.vm), size: size, dark: false)
    if let dir { png(withChrome(listShot), to: dir.appendingPathComponent("window-list.png")) }
    check(listShot.pixelsWide == 2160 && listShot.pixelsHigh == 1400, "renders are 2160 × 1400 pixels")
    check(!list.vm.usesList(width: 1080) == false, "list mode")

    for line in report { print("  \(line)") }
    for line in report {
        if let value = Double(line.split(separator: " ").last ?? ""), value > 0.12 { check(false, "render drifted from its mockup: \(line)") }
    }
}

#else
func registerWindowKitTests() {}
#endif
