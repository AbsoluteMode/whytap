import Foundation

/// The badge window as the stack drives it.
@MainActor
protocol HotkeyBlockerBadgeSurface: SecureInputHolderPresenting {
    /// Set by the stack; called when a non-persistent badge fades by itself.
    var onSelfDismiss: (() -> Void)? { get set }
}

/// One badge beside the island, two reasons for it: an app holding Secure
/// Input and an app intercepting a Whytap shortcut with its own event tap.
/// Each guard owns its slot and never dismisses the other's badge. The most
/// recently presented badge is on screen; when it leaves, a persistent badge
/// of the other slot comes back, dimmed. The interceptor's badge is always
/// transient (about 3 s), so only Secure Input's dimmed logo ever comes back.
// WHY: .project-docs/decisions/2026-11-26-hotkey-interceptor-taps.md
@MainActor
final class HotkeyBlockerBadgeStack {
    enum Source: CaseIterable {
        case secureInput
        case interception
    }

    struct Entry: Equatable {
        let badge: SecureInputHolderBadge
        let persistent: Bool
    }

    static let shared = HotkeyBlockerBadgeStack(makeSurface: { SecureInputHolderPanel.shared })

    private let makeSurface: () -> HotkeyBlockerBadgeSurface
    private var surface: HotkeyBlockerBadgeSurface?
    private(set) var entries: [Source: Entry] = [:]
    private(set) var displayed: Source?
    private var slots: [Source: Slot] = [:]

    /// The window is created on the first badge, so launching makes none.
    init(makeSurface: @escaping () -> HotkeyBlockerBadgeSurface) {
        self.makeSurface = makeSurface
    }

    func presenter(for source: Source) -> SecureInputHolderPresenting {
        if let slot = slots[source] { return slot }
        let slot = Slot(stack: self, source: source)
        slots[source] = slot
        return slot
    }

    // MARK: - Slot operations

    fileprivate func present(_ badge: SecureInputHolderBadge, shake: Bool, persistent: Bool, from source: Source) {
        // A transient badge covered by another one is over: it never comes back.
        if let displayed, displayed != source, entries[displayed]?.persistent == false {
            entries[displayed] = nil
        }
        entries[source] = Entry(badge: badge, persistent: persistent)
        displayed = source
        resolvedSurface().present(badge, shake: shake, persistent: persistent)
    }

    fileprivate func dismiss(from source: Source) {
        guard entries.removeValue(forKey: source) != nil else { return }
        guard displayed == source else { return }
        displayed = nil
        surface?.dismiss()
        showRemaining()
    }

    fileprivate func isShowing(_ source: Source) -> Bool {
        guard entries[source] != nil else { return false }
        guard displayed == source else { return true }
        if surface?.isShowing == true { return true }
        // Faded without telling us (it is told in production).
        surfaceDidDismissItself()
        return entries[source] != nil
    }

    /// The displayed badge faded on its own (a shaken, non-persistent one).
    func surfaceDidDismissItself() {
        if let displayed, entries[displayed]?.persistent == false {
            entries[displayed] = nil
        }
        displayed = nil
        showRemaining()
    }

    private func showRemaining() {
        guard let (source, entry) = Source.allCases.lazy
            .compactMap({ source in self.entries[source].map { (source, $0) } })
            .first(where: { $0.1.persistent }) else { return }
        displayed = source
        resolvedSurface().present(entry.badge, shake: false, persistent: true)
    }

    private func resolvedSurface() -> HotkeyBlockerBadgeSurface {
        if let surface { return surface }
        let made = makeSurface()
        made.onSelfDismiss = { [weak self] in self?.surfaceDidDismissItself() }
        surface = made
        return made
    }

    /// What one guard sees: only its own badge.
    private final class Slot: SecureInputHolderPresenting {
        private weak var stack: HotkeyBlockerBadgeStack?
        private let source: Source

        init(stack: HotkeyBlockerBadgeStack, source: Source) {
            self.stack = stack
            self.source = source
        }

        func present(_ badge: SecureInputHolderBadge, shake: Bool, persistent: Bool) {
            stack?.present(badge, shake: shake, persistent: persistent, from: source)
        }

        func dismiss() { stack?.dismiss(from: source) }

        var isShowing: Bool { stack?.isShowing(source) ?? false }
    }
}
