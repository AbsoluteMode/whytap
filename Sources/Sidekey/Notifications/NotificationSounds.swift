import AppKit
import Combine
import Foundation

enum NotificationSound: String, CaseIterable {
    case none, glass, ping, pop

    var title: String {
        switch self {
        case .none: "Off"
        case .glass: "Glass"
        case .ping: "Ping"
        case .pop: "Pop"
        }
    }

    var fileURL: URL? {
        guard self != .none else { return nil }
        return URL(fileURLWithPath: "/System/Library/Sounds/\(title).aiff")
    }
}

/// Source preferences stay in the app, so scripts cannot turn sound on themselves.
@MainActor
final class NotificationSoundSettings: ObservableObject {
    static let shared = NotificationSoundSettings(defaults: .standard)
    private static let key = "notifications.sourceSounds"
    @Published private var selections: [String: String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        selections = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// Settings sync wrote another Mac's choices.
    func reloadFromDefaults() {
        let loaded = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        if loaded != selections { selections = loaded }
    }

    func sound(for source: String) -> NotificationSound {
        selections[source].flatMap(NotificationSound.init(rawValue:)) ?? .none
    }

    func setSound(_ sound: NotificationSound, for source: String) {
        selections[source] = sound.rawValue
        defaults.set(selections, forKey: Self.key)
    }
}

/// One short system sound at a time; bursts never become an overlapping chorus.
@MainActor
final class NotificationSoundPlayer {
    static let shared = NotificationSoundPlayer()
    private var active: NSSound?
    private var lastPlayed: TimeInterval = -.infinity

    func play(_ sound: NotificationSound, preview: Bool = false) {
        if preview { active?.stop() }
        guard let url = sound.fileURL else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard preview || now - lastPlayed >= 0.75 else { return }
        guard let next = NSSound(contentsOf: url, byReference: true) else { return }
        active?.stop()
        active = next
        if next.play() { lastPlayed = now }
    }
}
