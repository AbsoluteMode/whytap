import AppKit
import Combine
import Foundation

/// The filters shared by the History surfaces.
enum HistoryStripMode: String, CaseIterable, Equatable {
    case agent
    case drop
    case clipboard
}

/// Body of an expanded history card — the centered scrollable panel
/// that opens when the user clicks a card's expand button. The
/// associated enum carries the entry's mode so the expanded panel can
/// render the right header / content style.
enum HistoryStripExpandedEntry: Equatable {
    /// Title comes second so we can keep the simple `.text(String)`
    /// constructor for tests that don't care about chat metadata.
    case agent(AgentBody)
    case drop(DropBody)
    case clipboard(ClipboardBody)

    enum AgentBody: Equatable {
        case text(String)
        case full(title: String?, response: String, links: [URL])
    }

    enum DropBody: Equatable {
        case text(String)
        case full(raw: String, formatted: String, targetApp: String?)
    }

    enum ClipboardBody: Equatable {
        case text(String)
        case image(ClipboardImagePayload)
        case fileURLs([URL])
    }
}

/// Orchestrator for the history strip: which mode is open, whether an
/// expanded card panel is visible, and the input-event handlers (Esc,
/// outside-click) that close them.
///
/// View layer (`HistoryStripView` etc.) observes `openMode` and
/// `expandedEntry` via `@ObservedObject`; the `NSPanel` hosts read the
/// same to decide when to order in/out.
@MainActor
final class HistoryStripController: ObservableObject {
    static let lastModeDefaultsKey = "sidekey.history.lastMode"

    /// `nil` = strip is closed. Setting to a mode opens the strip on
    /// that mode; setting back to nil closes everything (collapse
    /// expanded first, then close strip).
    @Published private(set) var openMode: HistoryStripMode?

    /// Non-nil while the centered expanded card is visible on top of
    /// the strip. Always cleared when the strip closes.
    @Published private(set) var expandedEntry: HistoryStripExpandedEntry?

    /// ROO-208 iter 15: card the cursor is currently over inside the
    /// cards row. Updated by `HistoryCardView`'s `.onHover` via
    /// `setHoveredCard(_:)`. Drives the "Paste to <App> ↵" hint
    /// visibility AND the Enter-key paste flow — Enter with no hover
    /// is a no-op (we never paste a card the user can't see they
    /// selected). Always cleared when the strip closes.
    @Published private(set) var hoveredCard: HistoryStripCard?

    /// The app whose focused text input was validated when History opened.
    /// The strip keeps this target while it is open and clears it on close.
    /// With no target, the paste hint is hidden and Return does nothing.
    @Published private(set) var targetAppName: String?

    /// Bumped when a stored entry disappears outside the strip's own
    /// actions (Delete… from any History surface). `HistoryStripView`
    /// reads the feed on every render, so the bump refreshes its cards.
    @Published private(set) var contentRevision = 0

    /// Last sidebar filter the user picked. Mirrored into UserDefaults so
    /// Hover History can reopen the same mode the user chose last time,
    /// even across controller re-creation.
    private var lastFilter: HistoryStripMode?
    private let userDefaults: UserDefaults

    /// Init accepts `ownBundleIdentifier` for backwards-compatibility
    /// with iter-15/16 callsites and tests (e.g.
    /// `HistoryStripController(ownBundleIdentifier: nil)`) but the
    /// value is no longer used internally — iter 17 removed the
    /// `NSWorkspaceDidActivateApplicationNotification` observer that
    /// needed to filter Sidekey out of frontmost-app updates. Retained
    /// as a sink so the existing call sites compile unchanged.
    init(
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        userDefaults: UserDefaults = .standard
    ) {
        _ = ownBundleIdentifier
        self.userDefaults = userDefaults
        if let raw = userDefaults.string(forKey: Self.lastModeDefaultsKey),
           let mode = HistoryStripMode(rawValue: raw) {
            self.lastFilter = mode
        }
    }

    // MARK: - Mode control

    /// Mouse-click on an orb-action icon. Toggle / switch / open per the
    /// spec:
    ///  * No strip open -> open on `mode`.
    ///  * Strip open on same mode -> close.
    ///  * Strip open on different mode -> switch to `mode` (no close
    ///    intermission).
    func toggle(_ mode: HistoryStripMode) {
        if openMode == mode {
            close()
            return
        }
        // Switching from one mode to another collapses any expanded
        // card first — the expanded card is bound to a specific entry
        // from the OLD mode and would render bogus content otherwise.
        expandedEntry = nil
        hoveredCard = nil
        openMode = mode
        rememberFilter(mode)
    }

    /// ROO-208: sidebar filter tap. Switches the active filter while the
    /// strip stays open. No-op when the strip is closed (sidebar buttons
    /// only render when the strip is on screen). Same-filter taps are
    /// also no-ops so a re-click doesn't cross-fade against itself or
    /// collapse an active expanded card.
    func setFilter(_ filter: HistoryStripMode) {
        guard openMode != nil else { return }
        guard openMode != filter else { return }
        expandedEntry = nil
        hoveredCard = nil
        openMode = filter
        rememberFilter(filter)
    }

    /// Closes both the expanded card (if any) and the strip itself.
    /// Called by Esc (when only the strip is open), by outside-click,
    /// and by `toggle(_:)` on the same-mode case.
    func close() {
        expandedEntry = nil
        openMode = nil
        hoveredCard = nil
        targetAppName = nil
    }

    // MARK: - Expanded view

    /// Show a centered expanded view of the given entry. No-op when no
    /// strip is open — Maxim's contract: the expanded view only exists
    /// as an annotation on the strip, never on its own.
    func expand(_ entry: HistoryStripExpandedEntry) {
        guard openMode != nil else { return }
        expandedEntry = entry
    }

    /// Card-level toggle for the expand button (Round 2 UX 8). Per-card
    /// semantics:
    ///  * No expanded view open → open with `entry`.
    ///  * Expanded view open for the SAME entry → close (toggle).
    ///  * Expanded view open for a DIFFERENT entry → switch to `entry`.
    ///
    /// The "same entry" check is by Equatable on
    /// `HistoryStripExpandedEntry` — agent / drop / clipboard payloads
    /// all carry enough identity (response text, formatted body, image
    /// UUID, file URLs) that two cards from different rows produce
    /// non-equal entries.
    func toggleExpand(_ entry: HistoryStripExpandedEntry) {
        guard openMode != nil else { return }
        if expandedEntry == entry {
            expandedEntry = nil
            return
        }
        expandedEntry = entry
    }

    /// Clear the expanded card while leaving the strip open. Hooked up
    /// by the expanded panel's "x" button.
    func collapseExpanded() {
        expandedEntry = nil
    }

    /// A clipboard entry was deleted. Drops the hover and an expanded view
    /// of that copy (Enter must not paste it, the panel must not keep
    /// showing it), then refreshes the cards.
    func clipboardEntryRemoved(_ card: HistoryStripCard) {
        if hoveredCard == card { hoveredCard = nil }
        if case .clipboard(let entry) = card,
           expandedEntry == .clipboard(Self.expandedBody(for: entry.payload)) {
            expandedEntry = nil
        }
        contentRevision += 1
    }

    static func expandedBody(
        for payload: ClipboardHistoryEntryPayload
    ) -> HistoryStripExpandedEntry.ClipboardBody {
        switch payload {
        case .text(let s): return .text(s)
        case .image(let img): return .image(img)
        case .fileURLs(let urls): return .fileURLs(urls)
        }
    }

    func rememberedFilter(default defaultFilter: HistoryStripMode = .clipboard) -> HistoryStripMode {
        lastFilter ?? defaultFilter
    }

    func rememberFilter(_ filter: HistoryStripMode) {
        lastFilter = filter
        userDefaults.set(filter.rawValue, forKey: Self.lastModeDefaultsKey)
    }

    // MARK: - Input events

    /// Esc-key handler — closes expanded first, then the strip. The
    /// `NSEvent` local monitor installed by the strip's panel calls in
    /// here on `.keyDown` with `keyCode == 53` (Esc).
    func handleEsc() {
        if expandedEntry != nil {
            expandedEntry = nil
            return
        }
        if openMode != nil {
            close()
        }
    }

    /// Outside-click handler — the global mouse-down monitor installed
    /// by the strip's panel calls in here when the user clicks outside
    /// the strip AND outside the expanded card (when both are present).
    /// Always closes everything.
    func handleOutsideClick() {
        close()
    }

    // MARK: - Hover (ROO-208 iter 15)

    /// Mouse hover transition coming from a single `HistoryCardView`.
    /// `card == nil` means the cursor exited the card; we accept the
    /// nil ONLY if the exiting card matches the currently hovered card,
    /// so a fast diagonal cursor sweep (enter B before A's exit) does
    /// not erroneously clear an active hover state.
    func setHoveredCard(_ card: HistoryStripCard?, from emitter: HistoryStripCard? = nil) {
        if card == nil {
            // Exit transition: only clear if the exiting card is still
            // the hovered one. Lets B-enter race past A-exit without
            // the hint flickering off.
            if let emitter, hoveredCard == emitter {
                hoveredCard = nil
            } else if emitter == nil {
                hoveredCard = nil
            }
            return
        }
        hoveredCard = card
    }

    /// Sets the validated paste target's display name (or `nil` to
    /// indicate "no editable target"). Called after the AX text-focus
    /// validation when opening History.
    func setTargetAppName(_ name: String?) {
        targetAppName = name
    }

    // MARK: - Card payload → pasteboard (ROO-208 iter 15)

    /// Writes a card's underlying payload to `NSPasteboard.general`
    /// using the right pasteboard types for the payload kind:
    ///   * `.text`   → `.string`
    ///   * `.image`  → `pb.writeObjects([NSImage])` (sidecar-backed,
    ///                  falls back to the in-memory thumbnail data if
    ///                  the sidecar has been evicted)
    ///   * `.fileURLs` → `pb.writeObjects(urls as [NSURL])`
    ///
    /// Shared between the strip's click-to-copy flow
    /// (`HistoryStripView.copyCardToPasteboard`) and the Enter-paste
    /// flow (`HistoryStripPanel.handleEnterPaste`) so both surfaces
    /// produce identical pasteboard contents.
    ///
    /// Suppression contract is the caller's responsibility — this
    /// helper only writes. The click path raises the suppression flag
    /// for ~1.2s; the Enter-paste path doesn't need to (the explicit
    /// paste action's whole purpose is to keep the card on the
    /// pasteboard, so the watcher's bounce-recording is desired).
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
