import AppKit
import ApplicationServices

/// Gets positive evidence of an editable field out of apps that publish no
/// accessibility tree until asked.
///
/// Electron apps (Claude, Slack, VS Code and most chat clients) answer the
/// focus query with "no value" until an assistive client sets
/// `AXManualAccessibility` on them; about a second later they report the real
/// focused element. The wake word needs that evidence (unknown focus is a no),
/// so it asks the app once and looks again, instead of guessing.
/// WHY: .project-docs/decisions/2026-11-11-wake-word.md
@MainActor
final class WakeWordFocusProbe {
    /// When to look again after asking; the tree was seen to appear between
    /// 0.7 s and 1.5 s on a real Electron app.
    static let retryDelays: [Duration] = [.milliseconds(400), .milliseconds(600), .milliseconds(700), .milliseconds(900)]

    typealias FocusCheck = @MainActor (_ pid: pid_t, _ bundleIdentifier: String?) -> Bool
    typealias TreeRequest = @MainActor (_ pid: pid_t) -> Void

    private let hasEditableFocus: FocusCheck
    private let requestTree: TreeRequest
    private let frontmost: @MainActor () -> (pid: pid_t, bundleIdentifier: String?)?
    private let sleep: @Sendable (Duration) async -> Void
    private var asked: Set<pid_t> = []
    private var pending: Task<Void, Never>?

    init(
        hasEditableFocus: @escaping FocusCheck = { pid, bundleIdentifier in
            PasteTargetValidator.appHasFocusedTextInput(
                pid: pid, bundleIdentifier: bundleIdentifier, requiringEvidence: true
            )
        },
        requestTree: @escaping TreeRequest = WakeWordFocusProbe.setManualAccessibility,
        frontmost: @escaping @MainActor () -> (pid: pid_t, bundleIdentifier: String?)? = {
            NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.bundleIdentifier) }
        },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.hasEditableFocus = hasEditableFocus
        self.requestTree = requestTree
        self.frontmost = frontmost
        self.sleep = sleep
    }

    /// Asks the app that just came to the front for its tree, so the first
    /// wake word there does not have to wait. Only while the wake word is on.
    func prepare(pid: pid_t, bundleIdentifier: String?) {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier, !asked.contains(pid),
              !hasEditableFocus(pid, bundleIdentifier) else { return }
        asked.insert(pid)
        requestTree(pid)
    }

    /// Calls `start` once the frontmost app shows an editable focused field:
    /// at once when it already does, or after asking for its tree. Never
    /// starts without that evidence, and never for an app that is no longer
    /// in front.
    func whenEditable(stillWanted: @escaping @MainActor () -> Bool, start: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = nil
        guard let app = frontmost() else { return }
        if hasEditableFocus(app.pid, app.bundleIdentifier) {
            start()
            return
        }
        asked.insert(app.pid)
        requestTree(app.pid)
        pending = Task { [weak self] in
            for delay in Self.retryDelays {
                await self?.sleep(delay)
                guard !Task.isCancelled, let self, stillWanted(),
                      self.frontmost()?.pid == app.pid else { return }
                if self.hasEditableFocus(app.pid, app.bundleIdentifier) {
                    start()
                    return
                }
            }
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Forgets apps that quit, so a relaunch (a new tree, off again) is asked.
    func forget(pid: pid_t) {
        asked.remove(pid)
    }

    static func setManualAccessibility(_ pid: pid_t) {
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
    }
}
