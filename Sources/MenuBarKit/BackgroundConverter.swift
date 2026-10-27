import Foundation
import SuperConverterCore

/// Converts files without the main window and says when it is done (ux §5.9, §5.10): Quick Actions, Services, the menu-bar
/// panel and `superconverter://convert` all end here. Results go to the person's chosen place with the saved options; the
/// finished files join the recent list and a notification names them.
@MainActor
final class BackgroundConverter {
    var recents: RecentList
    var notifier: BatchNotifying
    /// Called after the recent list changed (the open panel refreshes).
    var onRecentsChanged: (() -> Void)?

    init(recents: RecentList = RecentList(), notifier: BatchNotifying? = nil) {
        self.recents = recents; self.notifier = notifier ?? SystemNotifier()
    }

    /// Converts `urls` to `target`, or to each file's default target. The task ends when every file has.
    @discardableResult
    func convert(_ urls: [URL], target: FormatID?) -> Task<BatchSummary, Never> {
        Task { @MainActor in
            let place = Defaults[.outputPlace]
            let items = await BatchRunner.run(BatchRunner.prepare(urls, preset: target), place: place)
            return finish(items, place: place, notify: true)
        }
    }

    /// Records what finished and posts the notification (when "Notify when done" is on and `notify` says the person is not
    /// already watching).
    @discardableResult
    func finish(_ items: [BatchItem], place: OutputPlace, notify: Bool) -> BatchSummary {
        let summary = BatchSummary(items: items, place: place)
        let now = Date()
        let finished = summary.succeeded.compactMap { item -> RecentConversion? in
            guard let source = item.source, case .done(let result) = item.state, let output = result.outputs.first else { return nil }
            return RecentConversion(sourceName: item.name, sourceFormat: source, output: output, date: now)
        }
        if !finished.isEmpty { recents.add(finished); onRecentsChanged?() }
        if notify, Defaults[.notifyWhenDone], summary.total > 0 {
            notifier.post(title: summary.title, body: summary.detail, reveal: summary.firstOutput)
        }
        return summary
    }
}
