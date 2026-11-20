import Foundation

/// Preserve the existing research-audio retention policy after retiring capture.
// WHY: docs/decisions/2026-11-05-retire-live-assistant.md
enum RetiredMeetingCaptureCleanup {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidekey/meeting-assistant-tests", isDirectory: true)
    }

    static func run(root: URL = Self.root) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
