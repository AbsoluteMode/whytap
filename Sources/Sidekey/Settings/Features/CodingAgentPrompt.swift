import SwiftUI

/// The coding agents a Copy prompt is written for. The prompt is the same
/// for each: it is plain text with the real paths of this Mac, so any agent
/// that can read and write local files can follow it.
// WHY: .project-docs/decisions/2026-11-24-hover-notify-monitor-screens.md
enum CodingAgent: String, CaseIterable, Identifiable {
    case claudeCode
    case codex
    case cursor
    case antigravity

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        }
    }

    /// A monochrome mark in `Resources/UsefulLinkIcons`.
    var assetName: String {
        switch self {
        case .claudeCode: return "claude-code"
        case .codex: return "codex"
        case .cursor: return "cursor"
        case .antigravity: return "antigravity"
        }
    }

    /// "Claude Code, Codex, Cursor or Antigravity".
    static var names: String {
        let all = allCases.map(\.name)
        return all.dropLast().joined(separator: ", ") + " or " + (all.last ?? "")
    }
}

/// What a person pastes into their coding agent so it connects a source to
/// Notify or writes a dashboard for Monitor. Built from the paths this Mac
/// really uses and the contracts the app enforces (`NotifySetupGuide`,
/// `NotifyScript`, `MonitorDashboard`, `MonitorServerConfiguration`), so a
/// prompt cannot point somewhere the app does not read.
// WHY: .project-docs/decisions/2026-11-24-hover-notify-monitor-screens.md
enum CodingAgentPrompt {
    static func notify(root: URL) -> String {
        let sources = root.appendingPathComponent("sources", isDirectory: true).path
        let logos = root.appendingPathComponent("logos", isDirectory: true).path
        return """
        I use Whytap, a macOS app that lives in the notch. Help me add my own notification source to its Notify tool.

        Read the setup guide Whytap keeps on this Mac before you start. It has the full contract, the limits and how to verify delivery:
        \(root.appendingPathComponent("README.md").path)

        The short version
        - A notification is a text card to the left of the island: logo, title, body, colour and an optional link that opens on click. Whytap has no notification server and nothing has to be rebuilt.
        - A source is a private local script plus a manifest: \(sources)/<id>.json, written atomically with mode 600. Required: id, name and command (an argv array whose first entry is an absolute executable path). Optional: enabled, intervalSeconds (5–86400), tint (#RRGGBB), logo, duration (2–60 seconds). At most 16 sources.
        - Whytap runs the script only while it is open and stops it when it quits. Without intervalSeconds the script stays alive; with it, the script makes one pass and exits.
        - The script prints one flushed JSON object per line: title, and optional body, id, tint, logo, duration and link. A stable id is never shown twice.
        - A logo is an SF Symbol or an image in \(logos) (PNG, JPEG or PDF up to 2 MB). Links may be https, http, tg, slack, linear, github or mailto, plus codex://threads/<id> and claude://code/continue?session=local_<uuid> for an existing local chat.

        What I want from you
        1. Ask me what I want to be notified about and where it comes from.
        2. Ask only for the access that source needs. Keep tokens in the macOS Keychain or my credential manager, never in the manifest, the arguments, the output or a repository.
        3. Write the script and the manifest. Run the script once with test output first, then install it and confirm one uniquely named test event in \(root.appendingPathComponent("history.json").path).
        4. Tell me what you connected and what you verified. The source then shows in Whytap Settings → Features → Notify with an on/off switch and a sound.

        Do not send messages to other people, do not install a LaunchAgent and do not change Whytap itself.
        """
    }

    static func monitor(root: URL) -> String {
        let dashboards = root.appendingPathComponent("dashboards", isDirectory: true).path
        return """
        I use Whytap, a macOS app that lives in the notch. Help me build a dashboard for its Monitor tool.

        How Monitor works
        - A dashboard is a passive JSON snapshot that a collector you write keeps replacing. Whytap rereads it and only displays it: a snapshot cannot run commands or grant access, and nothing has to be rebuilt.
        - Snapshots go to \(dashboards)/<id>.json. The id has letters, digits, dot, underscore or hyphen and starts with a letter or digit; "server-status" is reserved.
        - Root fields: id, title, and optional subtitle, systemImage (an SF Symbol), accentHex, updatedAt (ISO 8601 with seconds and time zone), staleAfterSeconds (5–86400, default 60) and widgets.
        - A widget has id, kind (metric, progress, status, text or chart) and title, and optional value (a string), unit, detail, progress (0–1), trendPercent, status, accentHex and points ([{"label": "...", "value": 0}], up to 512 finite numbers).
        - Limits: 2 MB and 128 widgets per file, widget ids unique within it.
        - Server status (CPU, RAM, load and GPU of Linux servers) is built in and set up in \(root.appendingPathComponent("servers.json").path) with existing SSH aliases. Create that file only if I ask to watch servers, and never put passwords in it.

        What I want from you
        1. Ask me what I want to watch and where the numbers come from.
        2. Write a collector that fetches them with a timeout, writes the snapshot to a temporary file in the same folder with private permissions, then renames it, so Whytap never reads half a file. Set updatedAt to when the numbers were measured.
        3. Show missing or failed values as unavailable, never as zero, and never present old numbers as fresh.
        4. Tell me how the collector keeps running and how to stop it. Then tell me how to check: hover the notch → Monitor → pick the dashboard.

        Use my existing SSH and credential configuration. Do not restart services or change anything on my servers, and keep keys and passwords out of the snapshot, the collector's arguments and any repository.
        """
    }
}

/// Copy prompt's state: the prompt goes to the clipboard and the button
/// says "Copied" for a moment, then reads Copy prompt again.
@MainActor
final class PromptCopier: ObservableObject {
    @Published private(set) var copied = false
    private let copy: (String) -> Void
    private let shownFor: Duration
    private var resetTask: Task<Void, Never>?

    init(copy: @escaping (String) -> Void, shownFor: Duration = .seconds(2)) {
        self.copy = copy
        self.shownFor = shownFor
    }

    func copy(_ prompt: String) {
        copy(prompt)
        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self, shownFor] in
            try? await Task.sleep(for: shownFor)
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    func cancel() {
        resetTask?.cancel()
        copied = false
    }
}

/// "Let your coding agent set it up": the agents it works with, the prompt
/// on demand, and Copy prompt. Copying says so on the button for a moment.
@MainActor
struct CodingAgentPromptCard: View {
    let title: String
    let text: String
    let prompt: String
    @StateObject private var copier: PromptCopier
    @State private var shown = false

    init(title: String, text: String, prompt: String, copy: @escaping (String) -> Void) {
        self.title = title
        self.text = text
        self.prompt = prompt
        _copier = StateObject(wrappedValue: PromptCopier(copy: copy))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: title)
            MacCard {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Let your coding agent set it up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.text)
                    Text(text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                MacRowSeparator()
                HStack(spacing: 12) {
                    CodingAgentMarks()
                    Spacer(minLength: 12)
                    MacButton(title: shown ? "Hide prompt" : "Show prompt") { shown.toggle() }
                        .fixedSize()
                    MacButton(title: copier.copied ? "Copied" : "Copy prompt", style: .primary) { copier.copy(prompt) }
                        .fixedSize()
                        .accessibilityLabel(copier.copied ? "Prompt copied" : "Copy prompt")
                        .accessibilityHint("Copies the prompt for \(CodingAgent.names)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if shown {
                    MacRowSeparator()
                    ScrollView {
                        Text(prompt)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(MacSettingsTheme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .frame(height: 240)
                    .accessibilityLabel("Prompt")
                }
            }
        }
        .onDisappear { copier.cancel() }
    }
}

/// The marks and names of the agents a prompt is written for.
struct CodingAgentMarks: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(CodingAgent.allCases) { agent in
                HStack(spacing: 5) {
                    ProviderBrandIcon(assetName: agent.assetName, size: 15, color: MacSettingsTheme.text)
                    Text(agent.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Works with \(CodingAgent.names)")
    }
}

/// The top of an island tool's screen: back to Features, its name and kind,
/// and what it does.
struct IslandFeatureHeader: View {
    let info: FeatureInfo
    let about: String
    let back: () -> Void
    @FocusState private var backFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: back) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Features").font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(MacSettingsTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(MacButtonInteractionStyle(highlight: MacSettingsTheme.accent, focused: backFocused))
            .focused($backFocused)
            .padding(.leading, -6)
            .accessibilityLabel("Back to Features")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(info.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                    .accessibilityAddTraits(.isHeader)
                Text(info.kind)
                    .font(.system(size: 13))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            Text(about)
                .font(.system(size: 13))
                .foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
