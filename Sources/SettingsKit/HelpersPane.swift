import SuperConverterCore
import SwiftUI

/// Helpers (ux §5.11, `settings-helpers.png`): every helper with what it unlocks, its status and its one button.
struct HelpersPane: View {
    @StateObject private var model: HelpersModel
    private let context: SettingsContext
    @State private var showFurther = false

    init(context: SettingsContext) {
        self.context = context
        _model = StateObject(wrappedValue: HelpersModel(manager: context.helpers() ?? NoHelpers.shared, open: context.open))
    }

    var body: some View {
        PaneScroll {
            PaneNote("Super Converter converts most files by itself. These free helpers add the rest. They install into your Library folder or Applications, never run on their own, and can be removed any time.")
            CardList {
                ForEach(Array(HelpersModel.main.enumerated()), id: \.element) { index, helper in
                    if index > 0 { RowDivider() }
                    HelperRow(model: model, context: context, helper: helper)
                }
                if showFurther {
                    ForEach(HelpersModel.further, id: \.self) { helper in
                        RowDivider()
                        HelperRow(model: model, context: context, helper: helper)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Button { showFurther.toggle() } label: {
                    Text(showFurther ? "Hide the others" : "Further down: \(HelpersModel.further.map { HelperCatalog.info($0).name }.joined(separator: ", "))")
                        .scFont(SCFont.body).foregroundStyle(Color.scSecondary).multilineTextAlignment(.leading)
                }.buttonStyle(.plain)
                Spacer(minLength: 12)
                Button(Strings.Helper.lookAgain) { model.lookAgain() }
            }
        }
    }
}

/// Stands in when no helper service is registered (a bare window): every helper reads as not installed and nothing installs.
@MainActor
private final class NoHelpers: HelperManaging {
    static let shared = NoHelpers()
    let statusChanges = AsyncStream<HelperID> { _ in }
    func status(of helper: HelperID) -> HelperStatus { .notInstalled }
    func install(_ helper: HelperID) -> AsyncStream<InstallProgress> {
        AsyncStream { $0.yield(.failed("Helpers aren’t available right now")); $0.finish() }
    }
    func remove(_ helper: HelperID) throws {}
    func lookAgain() {}
    func run(_ invocation: HelperInvocation) async throws -> HelperRunResult { HelperRunResult(exitCode: 1) }
    func automate(app: HelperID, script: String) async throws -> String { "" }
}

private struct HelperRow: View {
    @ObservedObject var model: HelpersModel
    let context: SettingsContext
    let helper: HelperID

    private var info: HelperInfo { HelperCatalog.info(helper) }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HelperIcon(helper: helper)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(info.name).scFont(SCFont.summary).foregroundStyle(Color.scLabel)
                    if let badge = model.badge(for: helper) { StatusBadge(text: badge.text, isGood: badge.isGood) }
                }
                let items = HelperUnlocks.items(for: helper)
                if !items.isEmpty {
                    PillFlow { ForEach(items, id: \.self) { Pill(text: $0.text, category: $0.category) } }
                }
                Text(model.detail(for: helper)).scFont(SCFont.meta).foregroundStyle(Color.scSecondary)
                if let note = model.note(for: helper) {
                    Text(note).scFont(SCFont.meta).foregroundStyle(Color.scLabel).textSelection(.enabled)
                }
                if let failure = model.failures[helper] {
                    Text(failure).scFont(SCFont.meta).foregroundStyle(Color.scFailure)
                }
            }
            Spacer(minLength: 12)
            trailing.frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contextMenu {
            Button("Choose location…") { if let url = context.chooseLocation() { model.setLocation(url, for: helper) } }
            if Defaults[.helperPath(helper)] != nil { Button("Use the usual location") { model.setLocation(nil, for: helper) } }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var trailing: some View {
        if let progress = model.progress(for: helper) {
            VStack(alignment: .trailing, spacing: 6) {
                Text(progress.text).scFont(SCFont.body).foregroundStyle(Color.scSecondary)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).tint(Color.scAccent).frame(width: 220)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Color.scAccent).frame(width: 220)
                }
            }
        } else {
            switch model.action(for: helper) {
            case .install:
                Button { model.install(helper) } label: {
                    Label(Strings.Helper.install, systemImage: "arrow.down.to.line").labelStyle(.titleAndIcon)
                }.buttonStyle(CapsuleButtonStyle(prominent: true)).accessibilityLabel("Install \(info.name)")
            case .remove:
                Button(Strings.Helper.remove) { model.remove(helper) }.buttonStyle(CapsuleButtonStyle(prominent: false))
                    .accessibilityLabel("Remove \(info.name)")
            case .get(let label):
                Button(label) { model.get(helper) }.buttonStyle(CapsuleButtonStyle(prominent: false))
                    .accessibilityLabel("Get \(info.name)")
            case .none:
                EmptyView()
            }
        }
    }
}

private struct StatusBadge: View {
    let text: String
    let isGood: Bool
    var body: some View {
        let tone = isGood ? Color.scSuccess : Color.scFailure
        Text(text).scFont(SCTextStyle(.text, 12, line: 14, .medium)).foregroundStyle(isGood ? Color(SCColor.colors(for: .spreadsheet).inkToken) : tone)
            .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(tone.opacity(0.16)))
    }
}

/// The helper's square icon: its initials on its category's deep colour (the mockup's LO, Ca, Pd, TeX).
private struct HelperIcon: View {
    let helper: HelperID

    private static let initials: [HelperID: String] = [
        .libreoffice: "LO", .iwork: "iW", .msoffice: "Of", .calibre: "Ca", .pandoc: "Pd", .tectonic: "TeX", .ghostscript: "Gs",
        .djvulibre: "Dj", .oda: "ODA", .libredwg: "Dw", .ffmpegGPL: "ff", .rar: "Rar", .sfark: "sfA",
    ]
    private static let categories: [HelperID: FormatCategory] = [
        .libreoffice: .cad, .iwork: .presentation, .msoffice: .spreadsheet, .calibre: .ebook, .pandoc: .cad, .tectonic: .cad,
        .ghostscript: .presentation, .djvulibre: .document, .oda: .cad, .libredwg: .vector, .ffmpegGPL: .video, .rar: .archive, .sfark: .audio,
    ]

    var body: some View {
        let colors = SCColor.colors(for: Self.categories[helper] ?? .document)
        let size = SCMetrics.Settings.helperIcon
        RoundedRectangle(cornerRadius: 10).fill(Color(colors.deepToken)).frame(width: size, height: size)
            .overlay(Text(Self.initials[helper] ?? "?").scFont(SCTextStyle(.rounded, 15, line: 18, .bold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

/// Dark capsule for the one prominent action (Install), grey for the rest.
private struct CapsuleButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scFont(SCFont.name)
            .foregroundStyle(prominent ? Color.white : Color.scLabel)
            .padding(.horizontal, 16).frame(height: 32)
            .background(Capsule().fill(prominent ? Color(nsColor: NSColor(hex: SCColor.nearBlack)) : Color.scControl))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Wraps its children onto lines.
private struct PillFlow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { WrapLayout(spacing: 6) { content } }
}

private struct WrapLayout: Layout {
    var spacing: CGFloat

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing)
        }
        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(subviews, width: bounds.width)
        for (subview, position) in zip(subviews, laid.positions) {
            subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }
}
