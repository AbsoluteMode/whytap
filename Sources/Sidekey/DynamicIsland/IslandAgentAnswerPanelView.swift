import SwiftUI

/// The island answer panel: query line, then the streaming answer body
/// (permission card, Pill 1 / Pill 2, rendered blocks, useful links).
/// Content renderers are the same ones the legacy `AgentResponsePanel`
/// used — only the host and chrome are new. The body itself is the shared
/// `AgentAnswerBodyView`, so the permission card and the "Thinking" Pill 1
/// placeholder are rendered THERE, not duplicated here.
@MainActor
struct IslandAgentAnswerPanelView: View {
    @ObservedObject var responseStore: AskResponseStore
    @ObservedObject var linksSelection: UsefulLinksSelectionState
    /// Card width. Driven from the island's `compactWidth` so the answer sits in
    /// the same centred dorozhka as the hover panel (pill width, centred under
    /// the notch) rather than the old fixed 336pt trailing card.
    var panelWidth: CGFloat = IslandFrameLayout.agentAnswerPanelWidth

    /// Resolves which `UsefulLinksBlock` the panel should attach the
    /// selection chip to: the LAST one in the rendered block list. A turn
    /// emits at most one useful_links block per the SSE contract, but
    /// scanning from the end means a follow-up block (or a future
    /// multi-block turn) wins over a stale earlier one. Returns nil when no
    /// useful_links block is present. `static` + pure so the resolution is
    /// unit-testable without constructing the view.
    static func latestUsefulLinks(in blocks: [UIBlock]) -> UsefulLinksBlock? {
        for block in blocks.reversed() {
            if case .usefulLinks(let payload) = block { return payload }
        }
        return nil
    }

    /// Resolves which `UsefulActionsBlock` the panel attaches the selection chip
    /// to: the LAST one in the rendered block list. Generalises
    /// `latestUsefulLinks` to the typed actions block — the live agent path
    /// emits `.usefulActions` (link / path / copy), not `.usefulLinks`.
    /// Scanning from the end means a follow-up block wins over a stale earlier
    /// one. Returns nil when no actions block is present. `static` + pure so the
    /// resolution is unit-testable without constructing the view.
    static func latestUsefulActions(in blocks: [UIBlock]) -> UsefulActionsBlock? {
        for block in blocks.reversed() {
            if case .usefulActions(let payload) = block { return payload }
        }
        return nil
    }

    var body: some View {
        // The card owns the permission card, Pill 1 (the request title), Pill 2
        // streaming/tool labels, and the rendered block list. The close
        // affordance ([Esc] [✕]) lives in the WING now (the `.answerControls`
        // face), NOT over the card: the wing sits empty in the answer phase, so
        // it is the natural home for the dismiss control. The click is caught at
        // the window level (`IslandPanel.sendEvent` against `answerCloseHotspot`,
        // now mapped onto the wing) — see docs/troubleshooting.md.
        //
        // No detached-panel background: the answer's components (query pill,
        // text, blocks) read as separate elements floating on the wallpaper
        // rather than inside one dark frosted card.
        AgentAnswerBodyView(
            store: responseStore,
            usefulLinksSelectionState: linksSelection,
            contentMaxWidth: panelWidth
        )
        // Vertical padding only: horizontal inset is dropped so the pills reach
        // the island's edges (they were ~24pt narrower than the Dynamic Island).
        .padding(.vertical, 12)
        .frame(width: panelWidth, alignment: .topLeading)
    }
}
