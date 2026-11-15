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
        let pb = NSPasteboard.general
        pb.clearContents()
        switch card {
        case .agent(let c):
            pb.setString(c.responseMarkdown, forType: .string)
        case .drop(let c):
            pb.setString(c.formattedText, forType: .string)
        case .clipboard(let c):
            switch c.payload {
            case .text(let s):
                pb.setString(s, forType: .string)
            case .image(let img):
                let url = img.sidecarURL(in: assetsDirectory)
                if let data = try? Data(contentsOf: url),
                   let image = NSImage(data: data) {
                    pb.writeObjects([image])
                } else if let thumbImage = NSImage(data: img.thumbnailData) {
                    // Sidecar evicted — fall back to the thumbnail
                    // bytes so the user still gets something pastable.
                    pb.writeObjects([thumbImage])
                }
            case .fileURLs(let urls):
                pb.writeObjects(urls as [NSURL])
            }
        }
    }
}
