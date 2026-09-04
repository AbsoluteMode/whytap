import AppKit
import SwiftUI

/// Try-Agent step. The left pane connects a local agent CLI (Claude Code
/// or Codex) via the real setup checklist — install / sign-in actions
/// reuse the Settings → Agents paths, info popovers explain each step,
/// and Skip lets users without a CLI move on. The right pane teaches the
/// hands-on attempt: the real Right-⌘ gesture is armed on this step
/// (`prepareOnboardingTryRuntime → startAgentIfEnabled`), so once
/// connected the user presses it and the answer renders in the Dynamic
/// Island answer panel.
///
/// Generic over `OnboardingAgentSetupSurface` so the same view drives the
/// live `RealOnboardingAgentSetupSurface` and the preview's mock.
struct OnboardingAgentTryScreen<Surface: OnboardingAgentSetupSurface>: View {
    @ObservedObject var surface: Surface
    let onBack: () -> Void
    let onContinue: () -> Void

    @EnvironmentObject private var locale: OnboardingLocale
    private var copy: OnboardingAgentTryCopy { onboardingAgentTryCopy(for: locale.language) }

    private static var pink: Color { Color(red: 0.97, green: 0.60, blue: 0.85) }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: OnboardingTheme.leftPaneWidth, alignment: .topLeading)
                .background(OnboardingTheme.bg)
                .overlay(
                    Rectangle().fill(OnboardingTheme.border).frame(width: 0.5),
                    alignment: .trailing
                )
            rightPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { surface.start() }
        .onDisappear { surface.stop() }
    }

    // MARK: - Left pane (connect)

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                headline
                Text(copy.subtitle)
                    .font(OnboardingTheme.sans(13.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OnboardingAgentConnectPane(surface: surface).padding(.top, 16)
            Spacer(minLength: 0)
            footer
        }
        .padding(EdgeInsets(top: 38, leading: 36, bottom: 22, trailing: 28))
    }

    private var headline: some View {
        // Leading verb is language-aware serif (RU → Playfair Display so the
        // Cyrillic renders, not tofu); the "Agent." brand word stays English
        // italic in both locales.
        (
            Text(copy.headlineLead).font(OnboardingTheme.serif(42, language: locale.language))
            + Text("Agent.").font(OnboardingTheme.serifItalic(42))
        )
        .foregroundColor(OnboardingTheme.ink)
        .kerning(-0.6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text(copy.back)
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(OnboardingTheme.muted)
                .padding(.horizontal, 12)
                .frame(height: 34)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if !surface.allSatisfied {
                Button(action: onContinue) {
                    Text(copy.skip)
                        .font(OnboardingTheme.sans(13, weight: .medium))
                        .foregroundColor(OnboardingTheme.muted)
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
            }

            Button(action: onContinue) {
                HStack(spacing: 6) {
                    Text(copy.ccontinue)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(OnboardingTheme.bg)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Capsule(style: .continuous).fill(OnboardingTheme.ink))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Right pane (press R⌘ → the real answer streams in below)

    /// The right pane only becomes usable once the agent is fully set up.
    /// `connectPressed` now lives inside `OnboardingAgentConnectPane`; the
    /// Try-Agent screen is retired (Task 6) and its right pane is no longer
    /// reachable in the active flow, so drive from `allSatisfied` alone.
    private var isConnected: Bool { surface.allSatisfied }

    private var rightPane: some View {
        ZStack {
            AgentTryRightBackdrop()
            VStack(spacing: 18) {
                AgentTryPrompt(connectedName: isConnected ? surface.provider.displayName : nil)
                answerCard
            }
            .frame(maxWidth: 380)
            .padding(EdgeInsets(top: 30, leading: 28, bottom: 30, trailing: 28))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The live "AGENT" answer card. The window chrome is constant; the body
    /// is whatever the surface renders — the real streamed agent answer in the
    /// app (`OnboardingAgentLiveAnswer`), a scripted stand-in in the preview.
    private var answerCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(OnboardingTheme.trafficRed).frame(width: 7, height: 7)
                Circle().fill(OnboardingTheme.trafficYellow).frame(width: 7, height: 7)
                Circle().fill(OnboardingTheme.trafficGreen).frame(width: 7, height: 7)
                Text("AGENT")
                    .font(OnboardingTheme.mono(9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(OnboardingTheme.faint)
                    .padding(.leading, 7)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(OnboardingTheme.surface2)
            .overlay(Rectangle().fill(OnboardingTheme.border).frame(height: 0.5), alignment: .bottom)

            Group {
                if isConnected {
                    surface.answerContent()
                } else {
                    notConnectedPlaceholder
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .padding(13)
            .background(OnboardingTheme.surface)
        }
        .frame(width: 360)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Self.pink.opacity(0.55), lineWidth: 0.75))
        .shadow(color: Self.pink.opacity(0.18), radius: 22, y: 10)
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    /// Shown in the answer card until the agent is connected — the trial only
    /// works after Connect.
    private var notConnectedPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(OnboardingTheme.faint)
            Text(copy.connectToTry(provider: surface.provider.displayName))
                .font(OnboardingTheme.sans(12.5))
                .foregroundColor(OnboardingTheme.muted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - "Press R⌘" prompt

private struct AgentTryPrompt: View {
    let connectedName: String?
    @State private var pulse = false

    private static let pink = Color(red: 0.97, green: 0.60, blue: 0.85)

    private var active: Bool { connectedName != nil }

    var body: some View {
        HStack(spacing: 8) {
            Text("R\u{2009}\u{2318}")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(minHeight: 22)
                .padding(.horizontal, 7)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.85)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            Text(active ? "Press and ask — your agent answers below." : "Connect an agent above to try this.")
                .font(OnboardingTheme.sans(12.5))
                .foregroundColor(active ? Color(red: 0.94, green: 0.78, blue: 0.89) : OnboardingTheme.muted)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Capsule(style: .continuous).fill(Self.pink.opacity(active ? 0.12 : 0.05)))
        .overlay(Capsule(style: .continuous).stroke(Self.pink.opacity(active ? 0.45 : 0.18), lineWidth: 0.75))
        .scaleEffect(active && pulse ? 1.03 : 1.0)
        .animation(active ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: pulse)
        .onAppear { if active { pulse = true } }
        .onChange(of: active) { _, now in pulse = now }
    }
}

// MARK: - Backdrop

private struct AgentTryRightBackdrop: View {
    var body: some View {
        OnboardingTheme.surface2
            .overlay(
                ZStack {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 0.97, green: 0.60, blue: 0.85).opacity(0.18), location: 0),
                            .init(color: .clear, location: 0.55)
                        ]),
                        center: UnitPoint(x: 0.5, y: 0.0),
                        startRadius: 0, endRadius: 560
                    )
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 0.55, green: 0.36, blue: 1.0).opacity(0.16), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.10, y: 1.0),
                        startRadius: 0, endRadius: 520
                    )
                }
            )
    }
}
