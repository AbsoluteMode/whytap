import SwiftUI

/// The inner answer stack shared by every agent answer surface (today the
/// Dynamic Island `IslandAgentAnswerPanelView`). Carries the permission
/// card, Pill 1 / Pill 2, and the rendered block list (including the
/// useful_links selection chip). Holds NO chrome of its own — the host
/// owns the window frame, close button, and height measurement — so any
/// surface renders the body bit-for-bit identically.
@MainActor
struct AgentAnswerBodyView: View {
    /// Max width the inner pills hug before truncating / wrapping. Pill 1
    /// caps its single-line title at this width; the value tracks the
    /// historical response-panel content width (336pt) so the pills keep
    /// their established proportions regardless of the host's own frame.
    static let panelWidth: CGFloat = 336
    /// Cap on Pill 2's markdown answer body — ≈25 lines of streamed text.
    /// `MarkdownBodyText` renders with a 12pt system font + `lineSpacing(2)`
    /// (≈16pt per line) and 7pt of inter-block spacing for headings/lists.
    /// 420pt fits roughly 25 plain wrapped lines; once the stream exceeds
    /// that, the pill's shape freezes and content scrolls inside the
    /// capsule, leaving Pill 1 glued to the top. Static constant on
    /// purpose — a rendered-glyph measurement would be exact but is
    /// over-engineering for a ceiling that only needs to be in the right
    /// neighbourhood.
    static let pill2AnswerMaxBodyHeight: CGFloat = 420

    @ObservedObject var store: AskResponseStore
    /// Selection state for the visible useful_links block, injected by the
    /// host so the rolling-hint chip and the hotkey controller share one
    /// source of truth.
    @ObservedObject var usefulLinksSelectionState: UsefulLinksSelectionState
    /// Max content width. The island answer card drives this from the island's
    /// `compactWidth` so the pills span the full Dynamic Island width — the old
    /// fixed 336pt left desktop showing at the sides on wide-notch MacBooks
    /// (compactWidth > 336). Defaults to the legacy 336 for any other host.
    var contentMaxWidth: CGFloat = AgentAnswerBodyView.panelWidth

    var body: some View {
        // Subtask A: VStack inter-pill spacing 10 → 6pt so Pill 1 and
        // Pill 2 sit closer together after the chrome shrink. With the
        // tighter pill paddings (9/5 vs 12/8) a 10pt gap reads as a
        // gulf; 6pt restores the visual rhythm.
        VStack(alignment: .leading, spacing: 6) {
            // Permission prompt card: shown when Claude Code asks to use a
            // gated tool (Bash / network / MCP-write). Rendered at the top
            // of the stack so it is prominent. Allow/Deny resolve the
            // pending ask via AskResponseStore.decide(_:).
            if let p = store.pendingPermission {
                PermissionPromptView(
                    prompt: p,
                    onAllow: { store.decide(.allow(inputJSON: p.inputJSON)) },
                    onDeny: { store.decide(.deny(message: "User declined in Whytap")) }
                )
            }

            // Pill 1: chat title from Nano. Surfaces as soon as a
            // turn is in flight ("Thinking" shimmer placeholder) and
            // stays on screen as the request artifact — shimmer
            // fades once the stream finishes, but the pill itself
            // sticks around until the user closes the panel.
            //
            // Lives at the TOP of the VStack so that, with the stack
            // bottom-anchored inside a bottom-anchored window, Pill 1
            // sits visually ABOVE Pill 2 (i.e. further from the orb).
            if shouldShowChatTitlePill {
                ChatTitlePill(
                    text: chatTitlePillText,
                    shimmer: chatTitlePillShimmer,
                    contentMaxWidth: contentMaxWidth
                )
            }

            // Pill 2: tool action label from Nano (e.g. "ищу в
            // интернете", "смотрю в Notion"). Visible only while
            // Sonnet is executing actions; replaced in place every
            // time `tool.executing` re-emits. Hidden after the
            // stream completes — the final answer is owned by
            // BlockRendererRegistry below.
            // Pill 2 carries the live label from Nano during tool
            // execution and then transitions in place to Sonnet's
            // streaming answer once `summary.delta` events start
            // flowing. Single capsule, multi-line, grows as text
            // arrives.
            //
            // Sits just under Pill 1 so it ends up CLOSEST to the orb
            // (bottom-anchored layout). As Pill 2's body grows during
            // a Sonnet stream, the VStack grows upward, which pushes
            // Pill 1 toward the top of the panel — exactly the visual
            // effect spec'd as "Pill 2 vytesnyaet Pill 1 naverkh".
            if let pillText = toolLabelPillText {
                ToolLabelPill(
                    text: pillText,
                    shimmer: toolLabelPillShimmer,
                    isAnswerMode: isAnswerMode
                )
            }

            ForEach(Array(displayBlocks.enumerated()), id: \.offset) { _, block in
                // useful_actions (and legacy useful_links) are special-cased so
                // the selection-marker chip + chip-click hooks wire through the
                // same `UsefulLinksSelectionState` the hotkey controller drives.
                // All other blocks pass through the registry untouched.
                if case .usefulActions(let payload) = block {
                    ActionsBlockView(
                        block: payload,
                        selectionState: usefulLinksSelectionState
                    )
                } else if case .usefulLinks(let payload) = block {
                    UsefulLinksBlockView(
                        block: payload,
                        selectionState: usefulLinksSelectionState
                    )
                } else {
                    BlockRendererRegistry.view(for: block, sources: store.sources)
                }
            }
        }
        // Subtask A: outer paddings 4/12 → 2/8 so the pill stack rides
        // closer to its surrounding window edges. Combined with the
        // tighter inter-pill spacing the overall stack height drops
        // by ~12pt, which is what Maxim wanted ("ллм блоки меньше").
        .padding(.top, 2)
        .padding(.horizontal, 0)
        .padding(.bottom, 8)
    }

    /// Pill 1 is the "request artifact". It surfaces the moment a turn
    /// starts (status flips away from `.ready`) and stays on screen until
    /// the user closes the panel — even after `done` lands. The only state
    /// that hides it is a fresh, untouched store (status == .ready, no
    /// title, no stream completed) and an explicit `.failed` (the state
    /// error block takes over visually then).
    private var shouldShowChatTitlePill: Bool {
        if store.status == .failed { return false }
        return store.status != .ready
            || store.streamCompleted
            || (store.chatTitle?.isEmpty == false)
    }

    /// Shimmer the title only while the turn is live. After `done` lands
    /// the pill stays as a static record of which chat this answer belongs
    /// to — the animation would imply "still thinking", which it isn't.
    private var chatTitlePillShimmer: Bool {
        store.status != .ready && store.status != .failed && !store.streamCompleted
    }

    /// Pill 2 content: Sonnet's streaming answer wins as soon as any text
    /// is in the typewriter; otherwise we show Nano's tool action label;
    /// otherwise nothing (Pill 2 hidden). Pill 1 owns the "Thinking"
    /// placeholder so Pill 2 stays empty during the warm-up phase.
    /// `nil` means hide.
    private var toolLabelPillText: String? {
        if store.status == .failed { return nil }
        if !store.streamingText.isEmpty {
            return store.streamingText
        }
        if let label = store.currentToolLabel, !label.isEmpty {
            return label
        }
        return nil
    }

    /// Shimmer Pill 2 while it carries the Nano action label. As soon as
    /// the streaming answer takes over the shimmer turns off — the user
    /// is now reading the actual response, not an in-flight status.
    private var toolLabelPillShimmer: Bool {
        guard !store.streamingText.isEmpty == false else { return false }
        guard !store.streamCompleted, store.status != .failed else { return false }
        return store.currentToolLabel?.isEmpty == false
    }

    /// `true` once Pill 2 has transitioned from "tool action label" to
    /// "Sonnet streaming answer". Drives layout (multi-line, smaller
    /// corner radius, plain text styling).
    private var isAnswerMode: Bool {
        !store.streamingText.isEmpty
    }

    private var chatTitlePillText: String {
        if let title = store.chatTitle, !title.isEmpty {
            return title
        }
        return "Thinking"
    }

    private var displayBlocks: [UIBlock] {
        if !store.blocks.isEmpty {
            // Text answers are rendered inside Pill 2's streaming
            // typewriter, not via the block renderer — filter them out
            // so they don't double-render under the pill.
            return store.blocks.filter { block in
                if case .textAnswer = block { return false }
                return true
            }
        }

        if store.status == .failed {
            return [
                .stateError(StateErrorBlock(
                    title: "Agent error",
                    subtitle: store.errorCode,
                    message: store.errorMessage ?? "Request failed.",
                    code: store.errorCode,
                    retryable: store.isErrorRetryable
                ))
            ]
        }

        return []
    }
}

/// Pill 1 — chat-title pill. Before Nano returns `chat.title` the text is
/// "Thinking". Once the title arrives the text typewriter-replaces in place.
/// After `done` the pill stays on screen as a static request artifact until
/// the user dismisses the panel. No spinner, no bullet — Pill 2 owns the
/// tool action labels separately.
private struct ChatTitlePill: View {
    let text: String
    let shimmer: Bool
    /// Cap on the title chip's width. Driven from the host's `contentMaxWidth`
    /// (the island's compactWidth) so a long request title spans the full
    /// Dynamic Island width instead of the legacy fixed 336pt.
    var contentMaxWidth: CGFloat = AgentAnswerBodyView.panelWidth
    /// Subtask C: Maxim "шрифты … про нейминг запроса" — drop the title
    /// font from 13pt semibold to 11pt semibold so the chip reads as a
    /// tight request label rather than a heading.
    private static let font: Font = .system(size: 11, weight: .semibold)

    var body: some View {
        // Subtask C: "для нейминга поле сделать поуже надо" — the chip
        // hugs its text instead of stretching to the panel width, pinned
        // leading inside the wider VStack so it sits flush with Pill 2.
        // Width is capped at `panelWidth` (see `.frame(maxWidth:)` below)
        // so a long title truncates at one line (lineLimit(1) + tail)
        // rather than overflowing the panel.
        HStack(spacing: 0) {
            Text(text)
                .font(Self.font)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Padding shrunk alongside the font (Subtask A): 12/8 → 9/4 so
        // the capsule's intrinsic envelope tracks the smaller glyphs
        // and the whole chip lands in the ~21pt-tall neighbourhood.
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        // Hug short titles, but CAP at the panel width so a long title
        // truncates instead of overflowing. The old `.fixedSize(horizontal:
        // true)` was the bug: it forced the full single-line text width
        // regardless of the parent, so a long title pushed the hosting
        // view past `panelWidth` and the NSWindow clipped every pill on
        // the right edge.
        .frame(maxWidth: contentMaxWidth, alignment: .leading)
        .background(
            // `.thickMaterial` is an NSVisualEffectView under the hood —
            // gives real frosted-glass blur of the wallpaper behind the
            // panel, not just a translucent tint. Without it the pill
            // reads "see-through" on dark backgrounds and the
            // wallpaper bleeds through the text.
            Capsule(style: .continuous)
                .fill(.thickMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// Pill 2 — carries either Nano's tool action label (single line) or
/// Sonnet's streaming answer (plain text, multi-line, grows in height as
/// text arrives). The border stays stable when the content transitions.
///
/// In answer mode the markdown body is capped at
/// `pill2AnswerMaxBodyHeight` (≈25 lines) and overflow scrolls inside
/// the capsule with `.defaultScrollAnchor(.bottom)`. Pill 1 stays glued
/// to the top of the panel regardless of how long Sonnet's answer gets.
private struct ToolLabelPill: View {
    let text: String
    let shimmer: Bool
    let isAnswerMode: Bool
    private static let labelFont: Font = .system(size: 13, weight: .medium)
    private static let answerFont: Font = .system(size: 14, weight: .regular)
    private static let cornerRadius: CGFloat = 16
    /// Measured height of the streamed markdown body. A bare ScrollView is
    /// GREEDY: without an external constraint `.frame(maxHeight:)` resolves
    /// to the full cap even for a one-line answer (the legacy NSPanel host
    /// used to clamp this from outside; the island host does not). Sizing
    /// the frame to the measured content keeps the capsule as small as the
    /// answer until the cap kicks in.
    @State private var answerBodyHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if isAnswerMode {
                    // Sonnet streams markdown. Below the cap the capsule
                    // grows with the measured content height; once the
                    // body hits the cap the frame freezes and overflow
                    // stays INSIDE the pill instead of pushing Pill 1 off
                    // screen. `defaultScrollAnchor(.bottom)` keeps the
                    // user looking at the freshest streamed text.
                    // `MarkdownBodyText` is the same renderer used by
                    // the canonical `text.answer` block.
                    ScrollView(.vertical, showsIndicators: false) {
                        MarkdownBodyText(text: text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: AnswerBodyHeightKey.self,
                                        value: proxy.size.height
                                    )
                                }
                            )
                    }
                    .onPreferenceChange(AnswerBodyHeightKey.self) { answerBodyHeight = $0 }
                    .frame(height: min(
                        max(answerBodyHeight, 1),
                        AgentAnswerBodyView.pill2AnswerMaxBodyHeight
                    ))
                    .defaultScrollAnchor(.bottom)
                    .scrollContentBackground(.hidden)
                } else {
                    Text(text)
                        .font(Self.labelFont)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        // Subtask A: paddings 12/8 → 9/5 so the capsule chrome doesn't
        // dwarf the body content. The body itself (MarkdownBodyText
        // 12pt with lineSpacing 2pt) is unchanged so the streamed
        // answer stays legible.
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Same frosted-glass treatment as Pill 1 — `.thickMaterial`
            // (NSVisualEffectView) blurs the wallpaper so the streaming
            // markdown is readable without bleed-through.
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.thickMaterial)
        )
        .overlay(
            ShineBorderView(
                shape: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous),
                lineWidth: 1.2
            )
        )
    }
}

/// Preference carrying the measured height of the streamed answer body up
/// to the ScrollView's sizing frame in `ToolLabelPill`.
private struct AnswerBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
