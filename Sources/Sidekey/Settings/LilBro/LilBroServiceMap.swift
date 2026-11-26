import Foundation

/// The whole service as Lil Bro's model reads it (REV 22): for every feature
/// what it does, how to use it, what it needs, every setting with its row id
/// and the common problems with the row that fixes each; then Keys & models,
/// API hints, Case, Coding tools and every other screen's rows.
///
/// Built from the code of this revision: `FeatureCatalog` (name, line,
/// about, shortcuts, activation, island tool, examples, requirements) and
/// `LilBroRow.catalog`. Only the problems below and the short sections on
/// Keys & models, Case and Coding tools are written by hand, and every row
/// they name must exist. The text is checked in at `docs/lil-bro/service-map.md`
/// (whytap.ai reads that file from the app checkout); `LilBroServiceMapTests`
/// fails when it is stale, when a feature lacks a part, or when a row is in
/// no block or in two.
// WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md (REV 22)
enum LilBroServiceMap {
    static let path = "docs/lil-bro/service-map.md"

    /// A problem a person meets, why, and the row that fixes it.
    struct Trouble: Equatable {
        let symptom: String
        let fix: String
        let rows: [String]
    }

    static var text: String {
        var out = [
            "# Whytap service map",
            "",
            "Generated from the app's code (`LilBroServiceMap`); do not edit by hand. Each \"- <row id>: <title> — <what it does>\" line is a row go_kind \"row\" opens; \"*\" lines are what a feature needs and its common problems.",
            "Shortcuts are named by what they do; the person can change their keys in Hotkeys or on the feature's screen.",
            "",
        ]
        for feature in AppFeature.allCases { out += block(feature) }
        out += sections()
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Features

    static func block(_ feature: AppFeature) -> [String] {
        let info = FeatureCatalog.info(for: feature)
        var out = ["## \(info.name) (\(info.kind)) · feature id `\(feature.rawValue)`", ""]
        out.append("What it does: \(info.line)" + (info.about.isEmpty ? "" : " \(info.about)"))
        out.append("How to use: " + usage(info))
        if !info.examples.isEmpty {
            out.append("\(info.examplesTitle): " + info.examples.map { "“\($0)”" }.joined(separator: "; ") + ".")
        }
        out.append("What it needs:")
        out += needs(feature).map { "* \($0)" }
        out.append("Settings (row id: title — what it does):")
        out += rows(of: feature).map { "- \($0.id): \($0.title) — \($0.about)" }
        out.append("Common problems:")
        out += problems(feature).map { trouble in
            "* \(trouble.symptom) → \(trouble.fix)" + (trouble.rows.isEmpty ? "" : " Rows: " + trouble.rows.joined(separator: ", ") + ".")
        }
        out.append("")
        return out
    }

    private static func usage(_ info: FeatureInfo) -> String {
        var parts: [String] = []
        switch info.activation {
        case .alwaysOn: parts.append("Always on, nothing to turn on.")
        case .userSwitch: parts.append("Turn it on with its switch on its screen.")
        case .islandTools(let tools):
            parts.append("Its tools show in the island when added in Toolbox: "
                         + tools.map { HoverToolRegistry.info(for: $0).title }.joined(separator: ", ") + ".")
        }
        if !info.hotkeys.isEmpty {
            parts.append("Shortcuts: " + info.hotkeys.map(\.label).joined(separator: ", ") + ".")
        }
        if let tool = info.feature.islandTool {
            parts.append("In the island it is the \(HoverToolRegistry.info(for: tool).title) tool.")
        }
        switch info.place {
        case .screen: parts.append("Settings: its own screen in Features.")
        case .tab(let tab): parts.append("Settings: the \(tab.title) tab.")
        case .tool(let tool): parts.append("Settings: Toolbox, the \(HoverToolRegistry.info(for: tool).title) tool.")
        }
        if !info.clipCaption.isEmpty { parts.append("Its clip shows: \(info.clipCaption)") }
        return parts.joined(separator: " ")
    }

    /// Every requirement in either Drop mode, with the row of the feature's
    /// What it needs that fixes it.
    private static func requirements(_ feature: AppFeature) -> [FeatureRequirement] {
        var seen: Set<String> = []
        var out: [FeatureRequirement] = []
        for mode in [TranscriptionMode.fast, .smart] {
            var snapshot = FeatureSetupSnapshot()
            snapshot.dropMode = mode
            for requirement in FeatureCatalog.requirements(for: feature, snapshot: snapshot)
            where seen.insert(requirement.id).inserted {
                out.append(requirement)
            }
        }
        return out
    }

    private static func needsRow(_ feature: AppFeature, _ requirement: FeatureRequirement) -> LilBroRow? {
        LilBroRow.at(screen: "\(SettingsWindowTab.features.rawValue)/\(feature.rawValue)", title: requirement.title)
    }

    private static func needs(_ feature: AppFeature) -> [String] {
        let list = requirements(feature)
        guard !list.isEmpty else { return ["Nothing to allow or pay for: no key, model or permission."] }
        return list.map { requirement in
            let row = needsRow(feature, requirement).map { " (row \($0.id))" } ?? ""
            return "\(requirement.title)\(requirement.optional ? " (optional)" : ""): \(requirement.detail)\(row)"
        }
    }

    private static func rows(of feature: AppFeature) -> [LilBroRow] {
        LilBroRow.catalog.filter { $0.feature == feature }
    }

    /// What goes wrong: one line per requirement, plus the feature's own.
    static func problems(_ feature: AppFeature) -> [Trouble] {
        requirements(feature).map { requirement in
            let own = needsRow(feature, requirement).map { [$0.id] } ?? []
            switch requirement.kind {
            case .permission(.systemAudio):
                return Trouble(symptom: "The other side of a call or the Mac's sound is not heard",
                               fix: "macOS asks for System audio recording when the first recording starts and Whytap cannot check it beforehand; allow Whytap in System Settings → Privacy & Security → Screen & System Audio Recording.",
                               rows: own)
            case .permission(let permission):
                return Trouble(symptom: "\(permission.title) is not allowed",
                               fix: "Allow it on this screen or in Permissions, then come back.",
                               rows: own + [permissionRow(permission)].compactMap { $0 })
            case .model(let ai):
                return Trouble(symptom: "\(requirement.title) is not set or its key does not work",
                               fix: "Choose a model, or add a key for a provider first (API hints says where to get one, some without a card); a key out of credit needs a top-up with that provider or another provider's model.",
                               rows: own + advancedRow(ai) + ["apiAndModels.apiKeys", "apiAndModels.apiHints"])
            case .subtitlesKey:
                return Trouble(symptom: "Subtitles do not start",
                               fix: "Add a Soniox key, or an OpenAI key without one.",
                               rows: own + ["apiAndModels.apiKeys", "apiAndModels.apiHints"])
            case .dropShortcut:
                return Trouble(symptom: "Nothing happens on Drop's shortcut",
                               fix: "Check that macOS delivers it: Retry shortcut, or the fix the row shows.",
                               rows: own + ["permissions.dropShortcut"])
            }
        } + own(feature)
    }

    /// The feature's own model under Keys & models → Advanced.
    private static func advancedRow(_ feature: AIFeature) -> [String] {
        let group: [AIFeature: String] = [.dropSmartCleanup: "dropSmart", .meetingNotes: "meetings", .agentVoice: "agent"]
        let id = "apiAndModels." + (group[feature] ?? feature.rawValue)
        return LilBroRow.named(id) == nil ? [] : [id]
    }

    private static func permissionRow(_ permission: FeaturePermission) -> String? {
        switch permission {
        case .keyboard: return "permissions.keyboard"
        case .microphone: return "permissions.microphone"
        case .screenRecording: return "permissions.screenRecording"
        case .systemAudio: return nil
        }
    }

    /// Problems of the feature itself, beyond what it needs.
    private static func own(_ feature: AppFeature) -> [Trouble] {
        switch feature {
        case .drop:
            return [
                Trouble(symptom: "The text does not appear where the cursor is",
                        fix: "Whytap pastes into the focused text field; it needs Keyboard control, and the cursor must be in a field that takes text.",
                        rows: ["permissions.keyboard"]),
                Trouble(symptom: "“Couldn't deliver” after speaking",
                        fix: "The provider failed; the recording is kept, so press Retry. A refused or out-of-credit key says so and is fixed in API keys.",
                        rows: ["apiAndModels.apiKeys"]),
                Trouble(symptom: "Music or videos go quiet while dictating",
                        fix: "Turn off Lower other audio while speaking.",
                        rows: ["drop.lowerOtherAudio"]),
                Trouble(symptom: "Wants cleaner text with punctuation and fixed slips",
                        fix: "Switch Drop to Smart (Drop Mode in the island or on Drop's screen); Smart needs a text model too.",
                        rows: ["toolbox.dropMode"]),
            ]
        case .agent:
            return [
                Trouble(symptom: "Nothing happens on the Agent's shortcut",
                        fix: "Turn the Agent on with its switch.", rows: ["agent.switch"]),
                Trouble(symptom: "The Agent only answers and does not change files or run commands",
                        fix: "Turn on Allow file edits and commands.", rows: ["agent.allowActions"]),
            ]
        case .meetings:
            return [
                Trouble(symptom: "No offer to take notes when a call starts",
                        fix: "Turn Meeting Notes on; or start notes yourself with its shortcut.",
                        rows: ["meetings.switch", "meetings.recordShortcut"]),
                Trouble(symptom: "No speaker names in the transcript",
                        fix: "Speaker names need a Soniox, Deepgram or ElevenLabs speech model.",
                        rows: ["meetings.needs.speechModel"]),
                Trouble(symptom: "The recording stopped by itself",
                        fix: "It ends when the call app stops using the microphone; when the call comes back Whytap offers Reconnect.",
                        rows: []),
            ]
        case .googleSearch:
            return [Trouble(symptom: "Its shortcut does nothing", fix: "Turn Google search on.", rows: ["googleSearch.switch"])]
        case .translateSubtitles:
            return [Trouble(symptom: "Translate or Subtitles is not in the island",
                            fix: "Add it to Your hover in Toolbox.", rows: ["translateSubtitles.card", "toolbox.yourHover"])]
        case .screenshots:
            return [Trouble(symptom: "Shot is not in the island", fix: "Add it to Your hover in Toolbox.",
                            rows: ["screenshots.card", "toolbox.yourHover"])]
        case .todo:
            return [Trouble(symptom: "To-do is not in the island", fix: "Add it to Your hover in Toolbox.",
                            rows: ["todo.card", "toolbox.yourHover"])]
        case .caseVault:
            return [
                Trouble(symptom: "Case is not in the island", fix: "Add it to Your hover in Toolbox.",
                        rows: ["case.card", "toolbox.yourHover"]),
                Trouble(symptom: "A coding agent cannot use a key",
                        fix: "The agent sees key names only and runs its command through Case, which puts the value in; it needs the Whytap plugin and the tool allowed in Integrations → Coding tools.",
                        rows: ["case.yourKeys", "other.integrations"]),
            ]
        case .hover:
            return [Trouble(symptom: "A tool is missing from the island or in the wrong place",
                            fix: "Show it on Hover's screen or in Toolbox → Your hover, and drag to reorder.",
                            rows: ["toolbox.yourHover"])]
        case .notify:
            return [Trouble(symptom: "No cards arrive",
                            fix: "Notify shows sources a coding agent connects: copy the Add your own prompt into your coding agent.",
                            rows: ["notify.addYourOwn"])]
        case .monitor:
            return [Trouble(symptom: "No dashboards",
                            fix: "A coding agent builds them: copy the Build a dashboard prompt into your coding agent.",
                            rows: ["monitor.buildDashboard"])]
        }
    }

    // MARK: Other screens

    /// Rows that belong to no feature's own screen, by screen.
    static var screenRows: [(title: String, intro: String, rows: [LilBroRow])] {
        let rest = LilBroRow.catalog.filter { $0.feature == nil }
        func on(_ tab: SettingsWindowTab, section: APIAndModelsSection? = nil) -> [LilBroRow] {
            rest.filter { $0.tab.resolved == tab && (section == nil || $0.apiSection == section) }
        }
        return [
            ("Keys & models → API keys", keysIntro, on(.apiAndModels, section: .keys)),
            ("Keys & models → Models", modelsIntro, on(.apiAndModels, section: .models)),
            ("Keys & models → Costs", "What your API keys have cost, by provider, feature and day.",
             on(.apiAndModels, section: .costs)),
            ("Keys & models → API hints", hintsIntro, on(.apiAndModels, section: .hints)),
            ("Hotkeys", "Every shortcut in one place; click one, press a new combination, Save changes.", on(.hotkeys)),
            ("Permissions", "macOS permissions Whytap uses and whether each is allowed; Refresh after changing them in System Settings.",
             on(.permissions)),
            ("Toolbox", "The island's tools: Your hover is what shows on hover, All tools lists every tool, and a tool's pane is that tool itself with its shortcut.",
             on(.toolbox)),
            ("General", "The island and the window: auto-hide, which display, screenshot protection, Backup and Integrations.",
             on(.other)),
            ("Integrations", integrationsIntro, on(.integrations)),
            ("Backup", "Encrypted backups of keys, passwords and settings in your private GitHub repository; keep the recovery code to restore.",
             on(.backup)),
        ]
    }

    static let keysIntro = "Provider keys: click a provider's tile to add, replace or remove its key (OpenAI, Anthropic, Soniox, Deepgram, ElevenLabs, OpenRouter, Tavily, or a custom server). Keys stay in the macOS Keychain. On this Mac downloads a free speech model that needs no key (Apple Silicon)."
    static let modelsIntro = "One speech model and one text model serve every feature; Advanced sets a feature's own. A row's status says when a model is not set or its key does not work."
    static let hintsIntro = "Where to get an API key: each provider's free or no-card offer, its sign-up link and which features it covers. The answer to “where do I get a key?”."
    static let integrationsIntro = "GitHub for Backup, the calendars Whytap reads, and Coding tools: coding agents (Claude Code, Codex and others) that use Whytap through its plugin, each allowed or refused once with a switch per tool. Allowed tools can read meetings, add Vocab and Filler words and change settings; Case keys stay hidden from them."

    private static func sections() -> [String] {
        var out = [
            "## Case and coding tools",
            "",
            "Case keeps secret keys on this Mac in projects. A coding agent sees key names, never values, and runs a command through Case, which puts the value in and hides it in the output. Coding tools reach Whytap through its plugin after you allow them once (Integrations → Coding tools).",
            "",
        ]
        for screen in screenRows {
            out.append("## \(screen.title)")
            out.append("")
            out.append(screen.intro)
            out += screen.rows.map { "- \($0.id): \($0.title) — \($0.about)" }
            out.append("")
        }
        return out
    }

    /// Every row id the map names in a problem.
    static var troubleRows: [String] {
        AppFeature.allCases.flatMap { problems($0).flatMap(\.rows) }
    }
}
