import AppKit
import SwiftUI

/// The agent wing CONTENT: the inner faces drawn INSIDE the island's
/// single black surface (no background of its own). Faces: an inline text
/// field while composing, a live transcript ticker while recording, a
/// collapsed activity slot while the agent works, and a transient failure
/// notice. The black capsule + its rounded corners are owned by
/// `IslandCameraSurface`, which stretches rightward to host these faces;
/// this view only lays out the content so the island reads as one
/// continuous surface, not a separate bordered component. The composing face is
/// passive: the key-capable text view lives in `IslandAgentComposerPanel`,
/// positioned over this slot by `IslandPanel`.
struct IslandAgentWingView: View {
    let wing: IslandAgentFlowStore.Wing
    /// Width the active face is laid out at. Owned by `IslandView`
    /// (`activeWingFaceWidth`) so the rendered face, the black capsule's
    /// rightward stretch, and the face offset all key off one value.
    let faceWidth: CGFloat
    let activityLabel: String
    var recordingProviderBrand: TranscriptionProviderBrand? = nil
    let height: CGFloat
    let onComposingFocusChange: (Bool) -> Void

    /// Horizontal padding inside recording/composing faces. Shared so
    /// `IslandView`'s width measurement adds the exact same inset it renders.
    static let contentHorizontalPadding: CGFloat = 12

    /// Composer placeholder. Shared with `IslandView`'s width measurement so
    /// the composing face is never narrower than the full placeholder — an
    /// empty field used to collapse to the adaptive floor and truncate this
    /// to "Ask the a…".
    static let composerPlaceholder = "Ask the agent…"

    /// Composer placeholder shown when the surface belongs to the Google-search
    /// gesture (R-Option). Width measurement stays on `composerPlaceholder` —
    /// both strings are short and the adaptive floor handles the difference.
    static let googleComposerPlaceholder = "Google it…"

    /// True while the current on-screen surface belongs to the Google-search
    /// gesture rather than the agent. Drives the placeholder text rendered by
    /// the companion `IslandAgentComposerPanel`. Bound from `IslandView` via
    /// `agentFlow.activeSourceIsGoogle`; defaults to `false`.
    var isGoogle: Bool = false

    /// Recording placeholder. Used both for rendering and width measurement so
    /// the face never shrinks below the initial listening state when the first
    /// live partial is visually shorter than this word.
    static let recordingPlaceholder = "listening…"

    /// Label on the Retry pill in the total-offline `.deliveryFailed` wing
    /// (Task 7). Shared so `IslandPanel`'s window-level Retry hotspot and the
    /// wing width can reason about the same control.
    static let deliveryRetryLabel = "Retry"

    /// Extra width reserved past the measured text so the caret (and one more
    /// glyph) has room before the capsule has to grow again — keeps growth from
    /// lagging a character behind the typing.
    static let composingCaretSlack: CGFloat = 10

    /// Width of the composing capsule face for the currently typed `text`.
    /// Grows with the text from the placeholder floor (so an empty field opens
    /// snug, never cramped) up to `IslandFrameLayout.agentWingComposingWidth`;
    /// past the cap the capsule stops and the composer field scrolls to the
    /// caret instead of widening forever. This is the SINGLE source of truth
    /// for the composing width — the black capsule path (`IslandView`), the
    /// wing hit zone, and the composer field rect (`IslandPanel`) all read it,
    /// so they can never drift apart and leak text onto the desktop.
    // WHY: docs/decisions/2026-06-15-composer-capsule-grows-with-text.md
    static func composingFaceWidth(text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        func rendered(_ string: String) -> CGFloat {
            ceil((string as NSString).size(withAttributes: [.font: font]).width)
        }
        let content = max(rendered(text), rendered(composerPlaceholder))
            + contentHorizontalPadding * 2
            + composingCaretSlack
        return IslandFrameLayout.adaptiveWingWidth(
            measuredContentWidth: content,
            cap: IslandFrameLayout.agentWingComposingWidth
        )
    }

    /// Layout of the breathing provider mark inside the recording face.
    /// `IslandView`'s width measurement derives its extra allowance from
    /// these exact values (`recordingProviderMarkSlack`), so the rendered
    /// face and the measured face can never drift apart.
    static let recordingMarkSide: CGFloat = 16
    static let recordingMarkSpacing: CGFloat = 7
    /// Slightly tighter leading inset when the mark is present, so the mark
    /// optically aligns where the bare text used to start.
    static let recordingMarkLeadingPadding: CGFloat = 10

    /// Extra width the recording face needs beyond the measured text content
    /// when the provider mark is shown: the mark + its gap, minus the leading
    /// inset the mark variant gives back versus the text-only variant.
    static var recordingProviderMarkSlack: CGFloat {
        recordingMarkSide + recordingMarkSpacing
            + recordingMarkLeadingPadding - contentHorizontalPadding
    }

    static func recordingMeasuredContentWidth(text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let measurementText = text.isEmpty ? recordingPlaceholder : text
        let textWidth = ceil((measurementText as NSString).size(withAttributes: [.font: font]).width)
        return textWidth + contentHorizontalPadding * 2
    }

    static func recordingFaceWidth(
        text: String,
        providerMarkVisible: Bool
    ) -> CGFloat {
        let markSlack = providerMarkVisible ? recordingProviderMarkSlack : 0
        return IslandFrameLayout.adaptiveWingWidth(
            measuredContentWidth: recordingMeasuredContentWidth(text: text) + markSlack,
            cap: IslandFrameLayout.agentWingRecordingWidth
        )
    }

    static func actingMeasuredContentWidth(
        label: String,
        providerMarkVisible: Bool
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        if providerMarkVisible {
            return textWidth
                + recordingMarkSide
                + recordingMarkSpacing
                + recordingMarkLeadingPadding
                + 10
        }
        // dot (6) + HStack spacing (6) + leading/trailing padding (10 x 2)
        return textWidth + 6 + 6 + 20
    }

    static func actingFaceWidth(
        label: String,
        providerMarkVisible: Bool
    ) -> CGFloat {
        IslandFrameLayout.adaptiveWingWidth(
            measuredContentWidth: actingMeasuredContentWidth(
                label: label,
                providerMarkVisible: providerMarkVisible
            ),
            cap: IslandFrameLayout.agentWingActingWidth
        )
    }

    private var isComposingFace: Bool {
        if case .composing = wing { return true }
        return false
    }

    var body: some View {
        // Each face carries `.transition(.identity)` so a face↔face swap is an
        // INSTANT replace, never a cross-dissolve. The recording→thinking swap
        // used to cross-fade under the island's `wingFaceID` spring (driven from
        // `IslandView`): for one frame the live words AND the "thinking…" slot
        // were both on screen — worsened by a late final STT partial that
        // re-rendered fresh words a tick before the phase flipped (the drop
        // phase reaches the store via RunLoop.main). A child `.animation(nil)`
        // can't override that parent-driven transition; `.transition(.identity)`
        // on the conditional branches can — the outgoing face is removed
        // instantly, so there is no lingering ghost. The island's width/offset
        // still springs (that animation lives on `IslandView`, not here), and
        // the acting label keeps its own in-place transition for label↔label
        // changes (e.g. "thinking…" → a tool name).
        Group {
            switch wing {
            case .recording(let transcript):
                // Live transcript ticker only — no waveform. The orb (left of
                // the notch) already pulses on the voice; a second voice-reactive
                // waveform in the wing read as a duplicate. Leading-aligned so the
                // text sits flush after the notch — exactly where the waveform
                // used to begin — leaving no gap on the left.
                HStack(spacing: recordingProviderBrand == nil ? 0 : Self.recordingMarkSpacing) {
                    if let recordingProviderBrand {
                        IslandProviderBreathingIcon(brand: recordingProviderBrand)
                            .frame(
                                width: Self.recordingMarkSide,
                                height: Self.recordingMarkSide
                            )
                    }
                    Text(transcript.isEmpty ? Self.recordingPlaceholder : transcript)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(transcript.isEmpty ? 0.45 : 0.9))
                        .lineLimit(1)
                        .truncationMode(.head)   // виден ХВОСТ транскрипта
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                }
                .padding(
                    .leading,
                    recordingProviderBrand == nil
                        ? Self.contentHorizontalPadding
                        : Self.recordingMarkLeadingPadding
                )
                .padding(.trailing, Self.contentHorizontalPadding)
                .frame(width: faceWidth, height: height)
                .transition(.identity)
            case .acting:
                HStack(spacing: recordingProviderBrand == nil ? 6 : Self.recordingMarkSpacing) {
                    if let recordingProviderBrand {
                        IslandProviderBreathingIcon(brand: recordingProviderBrand)
                            .frame(
                                width: Self.recordingMarkSide,
                                height: Self.recordingMarkSide
                            )
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 6, height: 6)
                            .modifier(IslandAgentPulse())
                    }
                    Text(activityLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(activityLabel)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .padding(
                    .leading,
                    recordingProviderBrand == nil
                        ? 10
                        : Self.recordingMarkLeadingPadding
                )
                .padding(.trailing, 10)
                // Leading-aligned so the dot begins flush at the camera's right
                // edge (band left), not centred — centring left a wide gap
                // between the camera and the "thinking…" ticker.
                .frame(width: faceWidth, height: height, alignment: .leading)
                .transition(.identity)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(width: faceWidth, height: height, alignment: .leading)
                    .transition(.identity)
            case .deliveryFailed(let message):
                // Persistent total-offline Drop-delivery failure (Task 7). A
                // non-alarming message + a Retry pill. The Retry click is caught
                // at the window level (`IslandPanel.sendEvent` against
                // `deliveryRetryHotspot`), mirroring the answer ✕ — in this
                // non-key, non-activating panel the AppKit→SwiftUI bridge drops
                // the first-mouse click before any SwiftUI gesture fires. This is
                // the visual + VoiceOver layer only.
                HStack(spacing: 8) {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text(Self.deliveryRetryLabel)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.white.opacity(0.16))
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Retry delivery")
                    .accessibilityAddTraits(.isButton)
                }
                .padding(.horizontal, 12)
                .frame(width: faceWidth, height: height, alignment: .leading)
                .transition(.identity)
            case .composing:
                // The visible text field lives in `IslandAgentComposerPanel`
                // (positioned over this slot by `IslandPanel`). The placeholder
                // selection is computed here so the flag → string mapping has
                // a single home; `IslandPanel` reads `isGoogle` from the flow
                // store and passes the resolved string to the composer panel.
                let placeholder = isGoogle ? Self.googleComposerPlaceholder : Self.composerPlaceholder
                Color.clear
                    .frame(width: faceWidth, height: height)
                    .transition(.identity)
                    .accessibilityLabel(placeholder)
            case .answerControls:
                // Close controls for the centred answer card. Drawn on the
                // island's black surface, so no chrome — just the Esc hint and
                // the ✕ glyph. The actual click is caught at the window level
                // (`IslandPanel.sendEvent` against `answerCloseHotspot`, now
                // mapped onto the wing); this is the visual + VoiceOver layer.
                HStack(spacing: 7) {
                    Text("Esc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: faceWidth, height: height, alignment: .center)
                .accessibilityElement()
                .accessibilityLabel("Close")
                .accessibilityAddTraits(.isButton)
                .transition(.identity)
            case .hidden:
                EmptyView()
            }
        }
        .onChange(of: isComposingFace) { _, isComposing in
            onComposingFocusChange(isComposing)
        }
        .onAppear {
            if isComposingFace {
                onComposingFocusChange(true)
            }
        }
    }
}

/// Soft opacity pulse for the acting indicator dot.
private struct IslandAgentPulse: ViewModifier {
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
