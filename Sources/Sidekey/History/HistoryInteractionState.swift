import AppKit
import Foundation

/// The filters shared by the History surfaces.
enum HistoryStripMode: String, CaseIterable, Equatable {
    case agent
    case drop
    case clipboard
}

@MainActor
final class HistoryInteractionState {
    private static let lastModeDefaultsKey = "sidekey.history.lastMode"
    private let userDefaults: UserDefaults
    private var lastFilter: HistoryStripMode?
    private(set) var targetAppName: String?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        lastFilter = userDefaults.string(forKey: Self.lastModeDefaultsKey)
            .flatMap(HistoryStripMode.init(rawValue:))
    }

    func rememberedFilter() -> HistoryStripMode {
        lastFilter ?? .clipboard
    }

    func rememberFilter(_ filter: HistoryStripMode) {
        lastFilter = filter
        userDefaults.set(filter.rawValue, forKey: Self.lastModeDefaultsKey)
    }

    func setTargetAppName(_ name: String?) {
        targetAppName = name
    }

    /// Copies a history card for the island and Toolbox. Callers own clipboard suppression.
    func writeCardToPasteboard(_ card: HistoryStripCard, assetsDirectory: URL) {
        HistoryPasteboardWriter.writeAll(
            HistoryPastePlan.groups(for: [card]), to: .general, assetsDirectory: assetsDirectory
        )
    }

    /// Copies several marked rows at once, in mark order, as one pasteboard
    /// (`HistoryPasteboardWriter.writeAll`). One row is written as before.
    func writeCardsToPasteboard(_ cards: [HistoryStripCard], assetsDirectory: URL) {
        HistoryPasteboardWriter.writeAll(
            HistoryPastePlan.groups(for: cards), to: .general, assetsDirectory: assetsDirectory
        )
    }
}
