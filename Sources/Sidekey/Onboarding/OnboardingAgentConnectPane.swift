import AppKit
import SwiftUI

/// Loads a provider's real app icon (Claude / Codex) from the bundled
/// `UsefulLinkIcons` PNGs — `Bundle.module` in the preview, `Bundle.main` in
/// the Sidekey app. Full-colour (not a template). Returns nil when absent so
/// the caller can fall back to the drawn glyph.
func agentBrandIconImage(_ name: String) -> NSImage? {
    #if ONBOARDING_PREVIEW
    let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "UsefulLinkIcons")
    #else
    let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "UsefulLinkIcons")
    #endif
    guard let url else { return nil }
    return NSImage(contentsOf: url)
}

/// The agent Connect flow — provider chooser, setup checklist, and the
/// Connect CTA — extracted so both the retired Try-Agent screen and the
/// onboarding Skills page's Agent tab share one implementation. No live
/// R⌘ demo here; that lived only in the Try-Agent right pane.
struct OnboardingAgentConnectPane<Surface: OnboardingAgentSetupSurface>: View {
    @ObservedObject var surface: Surface
    /// Called when the user confirms the connection (Connect pressed with all
    /// checks satisfied). The Skills page uses this to flip the Agent
    /// capability on; the retired Try-Agent screen leaves it as the default no-op.
    var onConnected: () -> Void = {}
    @State private var infoStep: OnboardingAgentStep.Kind?
    @State private var connectPressed: Bool
    /// True while the connect probe is spawning the CLI.
    @State private var connecting = false
    /// Why the last Connect did not take, shown under the CTA.
    @State private var connectHint: String?
    /// Onboarding UI language (EN/RU). Injected by the flow / preview so the
    /// connect chrome and the localized checklist copy follow the toggle. ROO-261.
    @EnvironmentObject private var locale: OnboardingLocale

    /// Pick EN/RU for the pane's own chrome strings.
    private func t(_ en: String, _ ru: String) -> String { locale.language == .ru ? ru : en }

    /// `initiallyConnected` carries the Agent *capability* flag. The pane only
    /// shows "connected" when that is on AND the surface reports the selected
    /// provider as the active agent — capability-on with no connected provider
    /// leaves the CTA live, so Connect stays reachable.
    init(surface: Surface, initiallyConnected: Bool = false, onConnected: @escaping () -> Void = {}) {
        _surface = ObservedObject(wrappedValue: surface)
        self.onConnected = onConnected
        _connectPressed = State(initialValue: initiallyConnected)
    }

    private static var green: Color { Color(red: 0.31, green: 0.78, blue: 0.51) }

    private var steps: [OnboardingAgentStep] {
        OnboardingAgentSetupCatalog.steps(for: surface.provider, language: locale.language)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                providerToggle
                checklist.padding(.top, 14)
                connectButton.padding(.top, 16)
            }
            if let infoStep, let step = steps.first(where: { $0.kind == infoStep }) {
                infoPopover(step)
            }
        }
        // Kick off the brew/node/CLI/signed-in probes as soon as the pane is
        // shown. This kickoff used to live in the (now retired) Try-Agent
        // screen's `.onAppear`; the Skills page hosts the pane without it, so
        // the pane owns the kickoff now — otherwise the checklist sits at
        // `.checking` (spinner) forever. Idempotent: `start()` re-arms its poll
        // timer, safe to call each time the Agent detail re-appears.
        .onAppear { surface.start() }
        .onChange(of: surface.provider) { _, _ in
            connectPressed = false
            connectHint = nil
        }
    }

    private var providerToggle: some View {
        HStack(spacing: 8) {
            providerButton(.claude)
            providerButton(.codex)
        }
    }

    @ViewBuilder
    private func providerIcon(_ provider: OnboardingAgentProvider) -> some View {
        if let image = agentBrandIconImage(provider == .claude ? "claude" : "codex") {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        } else if provider == .claude {
            ClaudeGlyph()
        } else {
            CodexGlyph()
        }
    }

    private func providerButton(_ provider: OnboardingAgentProvider) -> some View {
        let selected = surface.provider == provider
        return Button(action: { withAnimation(.easeInOut(duration: 0.16)) { surface.provider = provider } }) {
            HStack(spacing: 7) {
                providerIcon(provider)
                    .frame(width: 22, height: 22)
                Text(provider.displayName)
                    .font(OnboardingTheme.sans(12.5, weight: .medium))
            }
            .foregroundColor(selected ? Color(red: 0.79, green: 0.73, blue: 0.98) : OnboardingTheme.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? OnboardingTheme.accent.opacity(0.14) : OnboardingTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? OnboardingTheme.accent.opacity(0.55) : OnboardingTheme.border, lineWidth: selected ? 0.75 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(t("SETUP", "НАСТРОЙКА"))
                    .font(OnboardingTheme.mono(9, weight: .semibold))
                    .tracking(0.7)
                Text("· \(surface.satisfiedCount) / 4")
                    .font(OnboardingTheme.mono(9, weight: .semibold))
                    .tracking(0.7)
            }
            .foregroundColor(surface.allSatisfied ? Self.green : OnboardingTheme.faint)

            ForEach(steps) { step in
                checklistRow(step)
            }
        }
    }

    @ViewBuilder
    private func checklistRow(_ step: OnboardingAgentStep) -> some View {
        let status = surface.status(for: step.kind)
        HStack(spacing: 10) {
            statusIcon(status)
            Text(step.title)
                .font(OnboardingTheme.sans(13))
                .foregroundColor(OnboardingTheme.ink)
            Button(action: { toggleInfo(step.kind) }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundColor(infoStep == step.kind ? OnboardingTheme.accent : OnboardingTheme.faint)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if status == .unsatisfied {
                Button(action: { runAction(step) }) {
                    Text(step.kind == .signedIn ? t("Sign in", "Войти") : t("Install", "Установить"))
                        .font(OnboardingTheme.sans(11, weight: .medium))
                        .foregroundColor(Color(red: 0.79, green: 0.73, blue: 0.98))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(OnboardingTheme.accent.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(rowEnabled(step.kind, status: status) ? 1 : 0.45)
    }

    /// "Signed in" only becomes actionable once the CLI is present.
    private func rowEnabled(_ kind: OnboardingAgentStep.Kind, status: OnboardingAgentStepStatus) -> Bool {
        if kind == .signedIn, surface.cli != .satisfied { return false }
        return true
    }

    @ViewBuilder
    private func statusIcon(_ status: OnboardingAgentStepStatus) -> some View {
        switch status {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 18, height: 18)
        case .satisfied:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Self.green)
                .frame(width: 18, height: 18)
        case .unsatisfied:
            Image(systemName: "circle")
                .font(.system(size: 13))
                .foregroundColor(OnboardingTheme.faint)
                .frame(width: 18, height: 18)
        }
    }

    private func infoPopover(_ step: OnboardingAgentStep) -> some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { infoStep = nil }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(OnboardingTheme.accent)
                    Text(step.title)
                        .font(OnboardingTheme.sans(12.5, weight: .medium))
                        .foregroundColor(OnboardingTheme.ink)
                    Spacer(minLength: 0)
                }
                Text(step.info)
                    .font(OnboardingTheme.sans(11.5))
                    .foregroundColor(OnboardingTheme.ink2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let command = step.command {
                    HStack(spacing: 8) {
                        Text(command)
                            .font(OnboardingTheme.mono(10.5))
                            .foregroundColor(Color(red: 0.79, green: 0.73, blue: 0.98))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button(action: { surface.copy(command) }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(OnboardingTheme.muted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(OnboardingTheme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
                }
                if let url = step.helpURL, let label = step.helpLabel {
                    Button(action: { surface.openURL(url) }) {
                        HStack(spacing: 4) {
                            Text(label)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(OnboardingTheme.sans(11, weight: .medium))
                        .foregroundColor(OnboardingTheme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(13)
            .frame(width: 260)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(OnboardingTheme.borderStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
            .onTapGesture {}
        }
        .transition(.opacity)
    }

    private func toggleInfo(_ kind: OnboardingAgentStep.Kind) {
        withAnimation(.easeInOut(duration: 0.14)) {
            infoStep = (infoStep == kind) ? nil : kind
        }
    }

    private func runAction(_ step: OnboardingAgentStep) {
        if let command = step.command {
            surface.copy(command)
        }
        surface.openTerminal()
    }

    // MARK: - Connect CTA (below the checklist)

    /// Explicit action to connect the selected agent, styled like the
    /// Notifications "Connect" button (ink capsule). Nothing connects on its
    /// own — the user presses this, and the provider probe (not the checklist)
    /// decides. WHY: docs/decisions/2026-08-02-onboarding-connect-is-probe-backed.md
    private var connectButton: some View {
        let done = connectPressed && surface.isConnected
        return VStack(alignment: .leading, spacing: 7) {
            Button(action: connect) {
                connectLabel(done: done)
            }
            .buttonStyle(.plain)
            .disabled(done || connecting)
            .animation(.easeInOut(duration: 0.2), value: done)

            if let connectHint {
                Text(connectHint)
                    .font(OnboardingTheme.sans(11.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func connectLabel(done: Bool) -> some View {
        if done {
            HStack(spacing: 6) {
                Circle().fill(Self.green).frame(width: 5, height: 5)
                Text("\(surface.provider.displayName) \(t("connected", "подключён"))")
                    .font(OnboardingTheme.sans(12, weight: .medium))
            }
            .foregroundColor(Self.green)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule(style: .continuous).fill(Self.green.opacity(0.12)))
        } else if connecting {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(t("Connecting…", "Подключаем…"))
                    .font(OnboardingTheme.sans(12, weight: .medium))
                    .foregroundColor(OnboardingTheme.muted)
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule(style: .continuous).fill(OnboardingTheme.surface))
        } else {
            Text("\(t("Connect", "Подключить")) \(surface.provider.displayName)")
                .font(OnboardingTheme.sans(12, weight: .medium))
                .foregroundColor(OnboardingTheme.bg)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule(style: .continuous).fill(OnboardingTheme.ink))
        }
    }

    /// Runs the real connect probe. The Homebrew / Node rows never gate it —
    /// a CLI installed outside Homebrew (Codex.app bundle, nvm-managed npm
    /// prefix) connects like any other. On refusal the hint says which step is
    /// actually missing and the matching command is copied to the clipboard.
    private func connect() {
        guard !connecting else { return }
        connecting = true
        connectHint = nil
        Task {
            let result = await surface.confirmConnection()
            connecting = false
            switch result {
            case .connected:
                withAnimation(.easeInOut(duration: 0.2)) { connectPressed = true }
                onConnected()
            case .notInstalled:
                connectHint = t(
                    "\(surface.provider.displayName) CLI not found. Command copied — run it in Terminal, then press Connect.",
                    "CLI \(surface.provider.displayName) не найден. Команда скопирована — выполните её в Терминале и нажмите «Подключить»."
                )
                guide(.cli)
            case .notSignedIn:
                connectHint = t(
                    "Not signed in yet. Command copied — run it in Terminal, sign in, then press Connect.",
                    "Вход не выполнен. Команда скопирована — выполните её в Терминале, войдите и нажмите «Подключить»."
                )
                guide(.signedIn)
            case .failed:
                connectHint = t(
                    "Couldn't reach the CLI. Check it in Terminal, then press Connect again.",
                    "Не удалось достучаться до CLI. Проверьте его в Терминале и нажмите «Подключить» ещё раз."
                )
            }
        }
    }

    /// Copy the step's command and open Terminal, so the refusal hint is
    /// immediately actionable.
    private func guide(_ kind: OnboardingAgentStep.Kind) {
        guard let step = steps.first(where: { $0.kind == kind }) else { return }
        runAction(step)
    }
}

// MARK: - Provider brand marks (drawn inline — preview-safe, no assets)

/// Anthropic / Claude Code sunburst — radiating spokes in Claude's coral.
struct ClaudeGlyph: View {
    var color = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer: CGFloat = min(size.width, size.height) * 0.5
            let inner: CGFloat = outer * 0.16
            let rays = 12
            for i in 0..<rays {
                let a: CGFloat = CGFloat(i) / CGFloat(rays) * 2 * .pi - .pi / 2
                // Pre-compute the trig terms as CGFloat so the type checker
                // does not have to unify CGFloat/Double across the nested
                // CGPoint initialisers — the single combined expression here
                // tripped "unable to type-check in reasonable time".
                let cosA: CGFloat = cos(a)
                let sinA: CGFloat = sin(a)
                var p = Path()
                p.move(to: CGPoint(x: c.x + cosA * inner, y: c.y + sinA * inner))
                p.addLine(to: CGPoint(x: c.x + cosA * outer, y: c.y + sinA * outer))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }
}

/// OpenAI / Codex blossom — six interlocking loops around a hexagonal centre,
/// in OpenAI's green. Closed elliptical loops (not rays) so it reads as the
/// knot mark rather than a sunburst.
struct CodexGlyph: View {
    var color = Color(red: 0.06, green: 0.64, blue: 0.50)

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) * 0.5
            let outer = r * 0.96
            let inner = r * 0.28
            let loopWidth = r * 0.52
            for i in 0..<6 {
                let a = CGFloat(Double(i) * .pi / 3)
                let rect = CGRect(x: -loopWidth / 2, y: -outer, width: loopWidth, height: outer - inner)
                let transform = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a)
                let loop = Path(ellipseIn: rect).applying(transform)
                ctx.stroke(loop, with: .color(color), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
            }
        }
    }
}
