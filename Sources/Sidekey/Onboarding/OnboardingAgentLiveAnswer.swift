import SwiftUI

/// Right-pane answer surface for the onboarding Try-Agent step, in the live
/// app. Renders the real production `AgentAnswerBodyView` fed by the very same
/// `AskResponseStore` the Dynamic Island uses — so when the user presses R⌘ on
/// this screen, the real agent's streamed answer (title pill, tool labels,
/// markdown, action blocks, permission cards) appears right here. Before any
/// turn runs it shows a quiet "press R⌘" placeholder with a few example asks.
///
/// Sidekey-only — references the production agent runtime (`AppState`,
/// `IslandPanel`, `AgentAnswerBodyView`, `AgentProviderStore`). The preview
/// target supplies `MockAgentSetupSurface.answerContent()` instead, which is
/// why this view is delivered through the `OnboardingAgentSetupSurface`
/// protocol as an `AnyView` rather than referenced from the symlinked screen.
@MainActor
struct OnboardingAgentLiveAnswer: View {
    /// Observed so a phase flip (R⌘ press → recording / executing) re-reads the
    /// live store below and swaps the placeholder for the streaming answer.
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        // Read the store fresh each pass: the real island flow store is
        // installed by `startAgentIfEnabled` when the Try step arms the
        // runtime, so this resolves to the live store the agent writes into.
        let store = IslandPanel.shared.agentFlow.responseStoreForViews
        let connected = AgentProviderStore.shared.activeProvider != nil
        let busy = appState.agentPhase != .idle
        let hasContent = !store.streamingText.isEmpty
            || !store.blocks.isEmpty
            || store.errorMessage != nil
            || store.pendingPermission != nil

        return Group {
            if busy || hasContent {
                AgentAnswerBodyView(
                    store: store,
                    usefulLinksSelectionState: IslandPanel.shared.agentLinksSelection,
                    contentMaxWidth: 320
                )
            } else {
                placeholder(connected: connected)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(connected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                keycap
                Text(connected
                    ? "Press R⌘ and ask your agent anything."
                    : "Connect an agent above to try it live.")
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.muted)
                Spacer(minLength: 0)
            }

            if connected {
                VStack(alignment: .leading, spacing: 6) {
                    exampleRow("Summarize the file I have open.")
                    exampleRow("What does this function do?")
                    exampleRow("Draft a commit message for my changes.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keycap: some View {
        Text("R\u{2009}\u{2318}")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(minHeight: 22)
            .padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }

    private func exampleRow(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(OnboardingTheme.faint.opacity(0.7))
            Text("“\(text)”")
                .font(OnboardingTheme.serifItalic(12.5))
                .foregroundColor(OnboardingTheme.faint)
        }
    }
}
