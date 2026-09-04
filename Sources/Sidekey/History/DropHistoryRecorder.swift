import Foundation

/// Records one `drop_entries` row per completed paste in the drop pipeline.
/// Decoupled from `AppDelegate` so we can unit-test the history side without
/// instantiating the full app lifecycle. Errors are swallowed — history
/// persistence must never break the user-visible paste flow.
struct DropHistoryRecorder {
    let store: any HistoryStore
    let clock: () -> Date

    init(store: any HistoryStore, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
    }

    func record(rawTranscript: String, formattedText: String, targetApp: String?) {
        do {
            try store.insertDropEntry(
                createdAt: clock(),
                rawTranscript: rawTranscript,
                formattedText: formattedText,
                targetApp: targetApp
            )
        } catch {
            // best-effort
        }
    }
}
