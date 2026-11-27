import SwiftUI

/// The screens of the features that have a switch: the Agent, Meeting Notes
/// and Google search. Each is the template with its own settings; the switch
/// writes the same flag as the island and the older Other tab.
// WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
@MainActor
struct SwitchFeatureScreen<Settings: View>: View {
    let feature: AppFeature
    let context: FeatureScreenContext
    @ViewBuilder var settings: Settings
    @StateObject private var model: FeatureSwitchModel

    init(feature: AppFeature, context: FeatureScreenContext, @ViewBuilder settings: () -> Settings) {
        self.feature = feature
        self.context = context
        self.settings = settings()
        _model = StateObject(wrappedValue: FeatureSwitchModel(
            feature: feature, isOn: FeatureCatalog.isOn(feature, snapshot: context.snapshot),
            environment: context.environment))
    }

    var body: some View {
        FeatureScreenView(feature: feature, context: context,
                          isOn: Binding(get: { model.isOn }, set: { model.turn($0) }),
                          busy: model.busy, problem: model.problem,
                          videoShortcuts: Self.videoShortcuts(feature, context.environment.hotkeys.configuration)) {
            settings
        }
        // A flag flipped elsewhere (the island, a nudge) shows here too.
        .onChange(of: FeatureCatalog.isOn(feature, snapshot: context.snapshot)) { _, now in
            model.follow(now)
        }
    }

    static func videoShortcuts(_ feature: AppFeature, _ configuration: HotkeyConfiguration) -> [FeatureVideoShortcut] {
        switch feature {
        case .agent: return AgentOtherSection.videoShortcuts(configuration)
        case .googleSearch: return SettingsOtherView.googleSearchVideoShortcuts(configuration)
        case .meetings:
            return [FeatureVideoShortcut(label: "Record", contents: configuration.meetingRecordShortcut.contents)]
        case .drop, .translateSubtitles, .screenshots, .history, .display, .todo, .calendar, .caseVault, .hover,
             .notify, .monitor: return []
        }
    }
}

/// A feature's switch on its screen: writes the same flag as the island and
/// Other. The Agent connects first and moves the switch only once it is on;
/// if it cannot, the card says why.
@MainActor
final class FeatureSwitchModel: ObservableObject {
    let feature: AppFeature
    private let environment: FeaturesEnvironment
    @Published private(set) var isOn: Bool
    @Published private(set) var busy = false
    @Published private(set) var problem: String?

    init(feature: AppFeature, isOn: Bool, environment: FeaturesEnvironment) {
        self.feature = feature
        self.isOn = isOn
        self.environment = environment
    }

    /// The flag changed elsewhere (the island, onboarding, a nudge). Once
    /// the feature is on, an earlier "why it did not turn on" is stale.
    func follow(_ now: Bool) {
        guard !busy else { return }
        isOn = now
        if now { problem = nil }
    }

    @discardableResult
    func turn(_ on: Bool) -> Task<Void, Never>? {
        problem = nil
        switch feature {
        case .agent:
            if !on { isOn = false }
            busy = true
            let environment = environment
            return Task {
                problem = await environment.setAgent(on)
                isOn = on && problem == nil
                busy = false
            }
        case .meetings:
            isOn = on
            environment.setMeetings(on)
        case .googleSearch:
            isOn = on
            environment.setGoogle(on)
        case .drop, .translateSubtitles, .screenshots, .history, .display, .todo, .calendar, .caseVault, .hover,
             .notify, .monitor:
            break
        }
        return nil
    }
}

/// The Agent's own setting: whether it may change files and run commands.
@MainActor
struct AgentFeatureSettings: View {
    @ObservedObject var settings: AgentSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Settings")
            MacCard {
                MacRow(title: AgentOtherSection.actionsTitle, subtitle: AgentOtherSection.actionsSubtitle) {
                    MacSwitch(isOn: $settings.allowActions, label: AgentOtherSection.actionsTitle)
                }
            }
            AgentSourcesSection(controller: SourcesController.shared)
                .padding(.top, 18)
        }
    }
}

/// Meeting Notes: the ready notification and the way to the notes.
@MainActor
struct MeetingsFeatureSettings: View {
    @ObservedObject var notifications: MeetingReadyNotifications
    let openNotes: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Settings")
            MacCard {
                MacRow(title: "Tell me when a note is ready",
                       subtitle: "A notification by the island; clicking it opens the note. Its sound is in Notify.") {
                    MacSwitch(isOn: $notifications.enabled, label: "Tell me when a note is ready")
                }
                MacRowSeparator()
                MacRow(title: "Your notes", subtitle: "Every note and its transcript, kept on this Mac.") {
                    MacButton(title: "Open notes", action: openNotes).fixedSize()
                }
            }
        }
    }
}
