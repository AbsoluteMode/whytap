import Foundation
import SwiftUI

/// Auto-cycling agent-setup surface for the preview. Walks the checklist
/// from "checking" through to all-connected and loops, so the Try-Agent
/// screen can be eyeballed without a real CLI. Actions are no-ops.
@MainActor
final class MockAgentSetupSurface: ObservableObject, OnboardingAgentSetupSurface {
    @Published var provider: OnboardingAgentProvider = .claude {
        didSet { if provider != oldValue { isConnected = false } }
    }
    @Published private(set) var homebrew: OnboardingAgentStepStatus = .checking
    @Published private(set) var node: OnboardingAgentStepStatus = .checking
    @Published private(set) var cli: OnboardingAgentStepStatus = .checking
    @Published private(set) var signedIn: OnboardingAgentStepStatus = .checking
    @Published private(set) var isConnected = false

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.runCycle()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Scripted connect: succeeds once the CLI + sign-in rows are green, and
    /// otherwise refuses with the step the preview is currently missing — the
    /// same shape as the real probe, so the pane's states can be eyeballed.
    func confirmConnection() async -> OnboardingAgentConnectResult {
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard cli == .satisfied else { return .notInstalled }
        guard signedIn == .satisfied else { return .notSignedIn }
        isConnected = true
        return .connected
    }

    func copy(_ text: String) {}
    func openTerminal() {}
    func openURL(_ url: URL) {}

    /// The preview can't run a real agent, so the answer surface is a scripted
    /// stand-in that loops placeholder → streamed answer → placeholder, letting
    /// the Try-Agent layout be eyeballed in both states.
    func answerContent() -> AnyView {
        AnyView(MockAgentAnswer())
    }

    private func runCycle() async {
        homebrew = .checking; node = .checking; cli = .checking; signedIn = .checking
        await sleep(1.0)
        guard !Task.isCancelled else { return }

        homebrew = .satisfied
        node = .satisfied
        cli = .unsatisfied
        signedIn = .unsatisfied
        await sleep(2.6)
        guard !Task.isCancelled else { return }

        cli = .satisfied
        signedIn = .checking
        await sleep(1.3)
        guard !Task.isCancelled else { return }

        signedIn = .satisfied
        await sleep(3.2)
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Scripted answer surface for the preview. Mirrors the shape of the real
/// `AgentAnswerBodyView` (query pill → tool/answer) closely enough to review
/// the Try-Agent right pane, then loops back to the placeholder.
private struct MockAgentAnswer: View {
    private enum Stage { case waiting, thinking, answered }
    @State private var stage: Stage = .waiting
    @State private var typed = ""

    private static let green = Color(red: 0.31, green: 0.78, blue: 0.51)
    private static let answer = "Done — closed ROO-234 and messaged Anna in Slack."

    var body: some View {
        Group {
            switch stage {
            case .waiting:
                placeholder
            case .thinking, .answered:
                answerBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await loop() }
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            Text("R\u{2009}\u{2318}")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(minHeight: 22)
                .padding(.horizontal, 7)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.85)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            Text("Press R⌘ and ask your agent anything.")
                .font(OnboardingTheme.sans(12.5))
                .foregroundColor(OnboardingTheme.muted)
            Spacer(minLength: 0)
        }
    }

    private var answerBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Pill 1 — the user query.
            Text("Close the auth bug and tell the PM")
                .font(OnboardingTheme.sans(11.5, weight: .medium))
                .foregroundColor(OnboardingTheme.ink2)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Capsule().fill(Color.white.opacity(0.05)))

            if stage == .answered {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Self.green)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Self.green.opacity(0.16)))
                    Text("Closed ROO-234 · let Anna know")
                        .font(OnboardingTheme.sans(11))
                        .foregroundColor(OnboardingTheme.ink2)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))

                Text(typed)
                    .font(OnboardingTheme.serif(13))
                    .foregroundColor(OnboardingTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Working…")
                        .font(OnboardingTheme.sans(11.5))
                        .foregroundColor(OnboardingTheme.muted)
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loop() async {
        while !Task.isCancelled {
            stage = .waiting; typed = ""
            await sleep(1.8)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { stage = .thinking }
            await sleep(1.4)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { stage = .answered }
            for ch in Self.answer {
                guard !Task.isCancelled else { return }
                typed.append(ch)
                await sleep(0.02)
            }
            await sleep(3.4)
        }
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
