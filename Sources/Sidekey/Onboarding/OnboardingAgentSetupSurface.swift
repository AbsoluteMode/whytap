import Foundation
import SwiftUI

/// Status of one agent-setup check, mirrored from the production
/// `AgentSetupStepStatus` but defined in the onboarding so the
/// `OnboardingPreview` target (which does not link the real agent
/// daemon) can drive the same screen with a mock.
enum OnboardingAgentStepStatus: Equatable {
    case checking
    case satisfied
    case unsatisfied
}

enum OnboardingAgentProvider: String, CaseIterable, Equatable {
    case claude
    case codex

    var displayName: String { self == .claude ? "Claude Code" : "Codex" }
}

/// Outcome of the pane's Connect action. Mirrors the production
/// `ConnectOutcome` without its payloads — the `OnboardingPreview` target does
/// not link the agent daemon, so the shared pane cannot name that type.
enum OnboardingAgentConnectResult: Equatable {
    case connected
    case notInstalled
    case notSignedIn
    case failed
}

/// One row of the connect checklist plus its info-popover copy.
struct OnboardingAgentStep: Identifiable {
    enum Kind: String { case homebrew, node, cli, signedIn }
    let kind: Kind
    let title: String
    let info: String
    let command: String?
    let helpURL: URL?
    let helpLabel: String?
    var id: String { kind.rawValue }
}

/// Static catalog of the four connect steps + their commands / help
/// links, keyed by provider. Pure data — safe for both targets.
enum OnboardingAgentSetupCatalog {
    static func steps(
        for provider: OnboardingAgentProvider,
        language: OnboardingUILanguage = .en
    ) -> [OnboardingAgentStep] {
        // Localized prose only (ROO-261). Tool/brand names (Homebrew, Node.js,
        // Claude Code CLI, Codex CLI), shell commands, and URLs stay English.
        func t(_ en: String, _ ru: String) -> String { language == .ru ? ru : en }
        let installGuide = t("Install guide", "Гайд по установке")

        let homebrew = OnboardingAgentStep(
            kind: .homebrew,
            title: "Homebrew",
            info: t(
                "macOS package manager the agent CLIs install through. Get it at brew.sh.",
                "Менеджер пакетов macOS, через который ставятся CLI агентов. Скачать — на brew.sh."
            ),
            command: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
            helpURL: URL(string: "https://brew.sh"),
            helpLabel: "brew.sh"
        )
        let node = OnboardingAgentStep(
            kind: .node,
            title: "Node.js",
            info: t(
                "Runtime the CLI needs. Installs via Homebrew.",
                "Среда выполнения, нужная CLI. Ставится через Homebrew."
            ),
            command: "brew install node",
            helpURL: URL(string: "https://nodejs.org"),
            helpLabel: "nodejs.org"
        )
        let signedInTitle = t("Signed in", "Вход выполнен")
        let cli: OnboardingAgentStep
        let signedIn: OnboardingAgentStep
        switch provider {
        case .claude:
            cli = OnboardingAgentStep(
                kind: .cli,
                title: "Claude Code CLI",
                info: t(
                    "Anthropic’s agent that runs locally on your machine. Install runs the command in Terminal; the row turns green by itself once it’s installed.",
                    "Агент Anthropic, работающий локально на вашей машине. «Установить» выполнит команду в Терминале; строка позеленеет сама после установки."
                ),
                command: "npm install -g @anthropic-ai/claude-code",
                helpURL: URL(string: "https://docs.claude.com/en/docs/claude-code/setup"),
                helpLabel: installGuide
            )
            signedIn = OnboardingAgentStep(
                kind: .signedIn,
                title: signedInTitle,
                info: t(
                    "Run the CLI once and sign in with your own Claude subscription. Whytap just detects it — no keys are stored here.",
                    "Запустите CLI один раз и войдите со своей подпиской Claude. Whytap просто определяет это — ключи здесь не хранятся."
                ),
                command: "claude",
                helpURL: nil,
                helpLabel: nil
            )
        case .codex:
            cli = OnboardingAgentStep(
                kind: .cli,
                title: "Codex CLI",
                info: t(
                    "OpenAI’s local coding agent. Install runs the command in Terminal; the row turns green by itself once it’s installed.",
                    "Локальный кодинг-агент OpenAI. «Установить» выполнит команду в Терминале; строка позеленеет сама после установки."
                ),
                command: "npm install -g @openai/codex",
                helpURL: URL(string: "https://developers.openai.com/codex/cli/"),
                helpLabel: installGuide
            )
            signedIn = OnboardingAgentStep(
                kind: .signedIn,
                title: signedInTitle,
                info: t(
                    "Run `codex login` and sign in with your OpenAI account. Whytap just detects it — no keys are stored here.",
                    "Выполните `codex login` и войдите в аккаунт OpenAI. Whytap просто определяет это — ключи здесь не хранятся."
                ),
                command: "codex login",
                helpURL: nil,
                helpLabel: nil
            )
        }
        return [homebrew, node, cli, signedIn]
    }
}

/// Backing surface for `OnboardingAgentTryScreen`. The screen is generic
/// over this so it drives the live `RealOnboardingAgentSetupSurface`
/// (Sidekey — wires into `AgentSetupChecklistViewModel` +
/// `AgentProviderStore`) and the `MockAgentSetupSurface` in the preview.
@MainActor
protocol OnboardingAgentSetupSurface: ObservableObject {
    var provider: OnboardingAgentProvider { get set }
    var homebrew: OnboardingAgentStepStatus { get }
    var node: OnboardingAgentStepStatus { get }
    var cli: OnboardingAgentStepStatus { get }
    var signedIn: OnboardingAgentStepStatus { get }

    /// True when the selected provider is the app's active agent, so the pane
    /// shows a truthful connected state on re-entry without re-probing.
    var isConnected: Bool { get }

    /// Begin polling (real) / the scripted cycle (mock).
    func start()
    func stop()

    /// Probe the selected provider and, on success, make it the active agent.
    /// The probe — not the four checklist rows — decides: Homebrew and Node
    /// guide a user starting from nothing, but they never gate the connection
    /// (the same contract Settings → Agents already runs on).
    func confirmConnection() async -> OnboardingAgentConnectResult

    /// Side-effecting actions — implemented with AppKit in the real
    /// surface, no-ops in the mock (keeps the screen preview-safe).
    func copy(_ text: String)
    func openTerminal()
    func openURL(_ url: URL)

    /// The right-pane answer surface. The real surface renders the live
    /// production `AgentAnswerBodyView` fed by the very `AskResponseStore`
    /// the Dynamic Island uses, so pressing R⌘ on this screen streams the
    /// real agent's answer right here. The mock returns a scripted stand-in
    /// — the preview target can't link the agent runtime. Type-erased to
    /// `AnyView` so the requirement stays identical across both targets.
    func answerContent() -> AnyView
}

extension OnboardingAgentSetupSurface {
    func status(for kind: OnboardingAgentStep.Kind) -> OnboardingAgentStepStatus {
        switch kind {
        case .homebrew: return homebrew
        case .node: return node
        case .cli: return cli
        case .signedIn: return signedIn
        }
    }

    var satisfiedCount: Int {
        [homebrew, node, cli, signedIn].filter { $0 == .satisfied }.count
    }

    var allSatisfied: Bool {
        [homebrew, node, cli, signedIn].allSatisfy { $0 == .satisfied }
    }

    /// Display name once everything is green (CLI present + signed in).
    var connectedProviderName: String? {
        allSatisfied ? provider.displayName : nil
    }
}
