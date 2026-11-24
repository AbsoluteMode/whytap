import ApplicationServices
import Foundation

/// Reads the focused field's Accessibility role and the containing document's
/// URL of a given process, so Smart can tell on this Mac a single-line field
/// (no markup) and Slack or Telegram in a browser (rich paste):
/// `SmartFormattingProfile.resolve`.
///
/// Only these two values are read. No text of the window (values, titles,
/// descriptions) is collected, and neither value goes into the cleanup
/// request. The request carries the transcript, Whytap's instructions, the
/// target app's name, and language and mode hints from the dictation path.
/// On the two rich-paste hosts the instructions say "Slack" or "Telegram"
/// instead of the browser's name; the address itself is never sent.
/// WHY: .project-docs/decisions/2026-11-22-smart-no-window-context.md
///
/// Permission: reuses the **Accessibility** grant the app already holds for
/// the hotkey monitors; no new permission is requested.
enum SmartFormattingMetadataReader {
    struct Snapshot: Sendable, Equatable {
        let documentURL: URL?
        let focusedRole: String?
    }

    /// Wall-clock ceiling for the whole read. The per-message AX timeout
    /// (0.5 s) bounds only a single message; an app that answers
    /// Accessibility slowly must never hold the take on "thinking…". On expiry
    /// the take proceeds without this metadata: the app is still named to the
    /// model, with no single-line guard and no rich paste in a browser.
    /// WHY: docs/decisions/2026-06-17-ax-context-snapshot-timeout.md
    static let defaultTimeout: Duration = .seconds(1.5)

    /// Off-main, time-bounded read. Returns `nil` when `pid` is `nil` (no
    /// known target), when the read does not finish within `timeout`, or when
    /// the calling task is cancelled. `collect` is injected for tests.
    static func snapshot(
        forPID pid: pid_t?,
        timeout: Duration = SmartFormattingMetadataReader.defaultTimeout,
        collect: @escaping (pid_t) -> Snapshot = SmartFormattingMetadataReader.liveSnapshot
    ) async -> Snapshot? {
        guard let pid else { return nil }
        // An AsyncStream lets the deadline win without waiting for synchronous
        // AX IPC to acknowledge cancellation. A task group would wait for its
        // losing child before returning. Late results are discarded.
        // WHY: docs/decisions/2026-09-07-smart-latency.md
        let results = AsyncStream<Snapshot?> { continuation in
            let work = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return }
                let value = collect(pid)
                guard !Task.isCancelled else { return }
                continuation.yield(value)
                continuation.finish()
            }
            let timer = Task.detached {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                continuation.yield(nil)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                work.cancel()
                timer.cancel()
            }
        }
        for await value in results { return value }
        return nil
    }

    // MARK: - Live AX read (production default)

    static func liveSnapshot(_ pid: pid_t) -> Snapshot {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return Snapshot(documentURL: nil, focusedRole: nil) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard !Task.isCancelled else { return nil }
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }
        func element(_ object: CFTypeRef?) -> AXUIElement? {
            guard let object, CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
        func url(_ object: CFTypeRef?) -> URL? {
            if let url = object as? URL { return url }
            if let text = object as? String {
                return text.hasPrefix("/") ? URL(fileURLWithPath: text) : URL(string: text)
            }
            return nil
        }
        guard let focused = element(value(app, kAXFocusedUIElementAttribute)) else {
            return Snapshot(documentURL: nil, focusedRole: nil)
        }
        let role = value(focused, kAXRoleAttribute) as? String
        var current: AXUIElement? = focused
        for _ in 0..<16 {
            guard let node = current, !Task.isCancelled else { break }
            if value(node, kAXRoleAttribute) as? String == "AXWebArea" {
                // Read the containing document, not links mentioned in content.
                return Snapshot(documentURL: url(value(node, "AXURL")), focusedRole: role)
            }
            if let document = url(value(node, kAXDocumentAttribute)), document.isFileURL {
                return Snapshot(documentURL: document, focusedRole: role)
            }
            current = element(value(node, kAXParentAttribute))
        }
        // Some browsers expose their page only as the window's AXDocument.
        if let window = element(value(app, kAXFocusedWindowAttribute)) {
            return Snapshot(documentURL: url(value(window, kAXDocumentAttribute)), focusedRole: role)
        }
        return Snapshot(documentURL: nil, focusedRole: role)
    }
}
