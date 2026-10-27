import SuperConverterCore
import SwiftUI

/// About (ux §5.11): version, updates, the privacy statement, licences and the source link.
struct AboutPane: View {
    let context: SettingsContext
    @StateObject private var model: AboutModel
    @Default(.checkForUpdates) private var automatic
    @State private var sections: [NoticeSection]?
    @State private var showLicences = false

    static let privacy = "Nothing leaves the Mac. The only network traffic: the update check (GitHub Releases, can be turned off), helper downloads you start with Install, and — only when you turn on “Load web resources” for one HTML file — that page’s own pictures and styles. No accounts, no analytics, no crash upload."
    static let noticesPage = SuperConverterPaths.repository.appendingPathComponent("blob/main/THIRD_PARTY_NOTICES.md")

    init(context: SettingsContext, showLicences: Bool = false) {
        self.context = context
        _model = StateObject(wrappedValue: AboutModel(updates: context.updates()))
        _showLicences = State(initialValue: showLicences)
        _sections = State(initialValue: showLicences ? Notices.load(from: context.noticesURL) : nil)
    }

    var body: some View {
        PaneScroll {
            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.appName).scFont(SCFont.display).foregroundStyle(Color.scLabel)
                Text("Version \(context.version)").scFont(SCFont.body).foregroundStyle(Color.scSecondary)
            }
            CardList {
                SettingsRow(title: "Updates", detail: model.statusText.isEmpty ? nil : model.statusText) {
                    HStack(spacing: 8) {
                        if model.readyVersion != nil { Button("Install and Restart") { model.installNow() } }
                        Button("Check for Updates") { model.checkNow() }.disabled(!model.canCheck)
                    }
                }
                RowDivider()
                SettingsRow(title: "Check for updates automatically") {
                    Toggle("Check for updates automatically", isOn: $automatic).labelsHidden().toggleStyle(.switch)
                }
            }
            CardList {
                SettingsRow(title: "Privacy", detail: Self.privacy) { EmptyView() }
            }
            CardList {
                SettingsRow(title: "Licences", detail: "Super Converter is MIT-licensed. It uses the open-source software listed here.") {
                    Button(showLicences ? "Hide" : "Show…") { toggleLicences() }
                }
                if showLicences { licences }
                RowDivider()
                SettingsRow(title: "Source code", detail: SuperConverterPaths.repository.absoluteString) {
                    Button("Open on GitHub…") { context.open(SuperConverterPaths.repository) }
                }
            }
        }
    }

    private func toggleLicences() {
        showLicences.toggle()
        if showLicences, sections == nil { sections = Notices.load(from: context.noticesURL) }
    }

    @ViewBuilder private var licences: some View {
        RowDivider()
        if let sections, !sections.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sections) { section in
                    DisclosureGroup(section.title) {
                        Text(section.body).scFont(SCFont.meta).foregroundStyle(Color.scSecondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
        } else {
            SettingsRow(title: "The notices are online", detail: "They are not bundled in this build.") {
                Button("Open…") { context.open(Self.noticesPage) }
            }
        }
    }
}
