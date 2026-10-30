import SuperConverterCore
import SwiftUI

/// General (ux §5.11): where results go, name collisions, and the on/off switches.
struct GeneralPane: View {
    let context: SettingsContext
    @Default(.outputPlace) private var place
    @Default(.collisionPolicy) private var collision
    @Default(.rememberFormatChoices) private var remember
    @Default(.showInMenuBar) private var showInMenuBar
    @Default(.convertOnMenuBarDrop) private var convertOnDrop
    @Default(.notifyWhenDone) private var notify
    @Default(.playSound) private var sound

    private enum PlaceChoice: Hashable { case next, downloads, folder }

    private var choice: Binding<PlaceChoice> {
        Binding(get: {
            switch place { case .nextToOriginal: .next; case .downloads: .downloads; case .folder: .folder }
        }, set: { newValue in
            switch newValue {
            case .next: place = .nextToOriginal
            case .downloads: place = .downloads
            case .folder:
                if let url = context.chooseFolder() { place = .folder(url) }
            }
        })
    }

    private var folderName: String? { if case .folder(let url) = place { url.lastPathComponent } else { nil } }

    var body: some View {
        PaneScroll {
            CardList {
                SettingsRow(title: "Save to") {
                    Picker("Save to", selection: choice) {
                        Text(Strings.ActionBar.nextToOriginals).tag(PlaceChoice.next)
                        Text("Downloads").tag(PlaceChoice.downloads)
                        Text(folderName.map { "Folder: \($0)" } ?? "Folder…").tag(PlaceChoice.folder)
                    }.labelsHidden().frame(width: 240)
                }
                RowDivider()
                SettingsRow(title: "When a file with that name exists") {
                    Picker("When a file with that name exists", selection: $collision) {
                        Text("Add a number").tag(CollisionPolicy.addNumber)
                        Text("Replace").tag(CollisionPolicy.replace)
                        Text("Ask").tag(CollisionPolicy.ask)
                    }.labelsHidden().frame(width: 240)
                }
                RowDivider()
                SettingsRow(title: "Keep originals", detail: "Converting never changes or removes the original files.") {
                    Text("Always").scFont(SCFont.body).foregroundStyle(Color.scSecondary)
                }
            }
            CardList {
                SettingsRow(title: "Remember my format choices", detail: "Use the format you chose last for each kind of file.") {
                    Toggle("Remember my format choices", isOn: $remember).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingsRow(title: "Show in menu bar") {
                    Toggle("Show in menu bar", isOn: $showInMenuBar).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                // ux §5.9: off by default; it only matters while the menu-bar item is there.
                SettingsRow(title: "Convert as soon as files are dropped on the menu bar") {
                    Toggle("Convert as soon as files are dropped on the menu bar", isOn: $convertOnDrop).labelsHidden().toggleStyle(.switch)
                        .disabled(!showInMenuBar)
                }
                RowDivider()
                SettingsRow(title: "Notify when done") {
                    Toggle("Notify when done", isOn: $notify).labelsHidden().toggleStyle(.switch)
                }
                RowDivider()
                SettingsRow(title: "Play a sound when done") {
                    Toggle("Play a sound when done", isOn: $sound).labelsHidden().toggleStyle(.switch)
                }
            }
            PaneNote("Appearance follows the system.")
        }
        .onChange(of: showInMenuBar) { _, visible in Services.menuBar?.setVisible(visible) }
    }
}
