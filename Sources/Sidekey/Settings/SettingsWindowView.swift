import AppKit
import SwiftUI

/// Settings shell: one predictable home for every user-facing preference.
@MainActor
struct SettingsWindowView: View {
    @ObservedObject var permissionsViewModel: PermissionsSettingsViewModel
    @ObservedObject var apiAndModelsViewModel: APIAndModelsViewModel
    @ObservedObject var selection: SettingsWindowSelection
    @ObservedObject var agentModeViewModel: AgentModeViewModel
    let toolboxDeps: ToolboxDeps
    let agentEnabled: () -> Bool
    let onAgentToggle: (Bool) -> Void
    // Other-tab deps. Capability seeds are live getters (not static Bools) so a
    // tab revisit re-reads the current value — see SettingsOtherView.onAppear.
    let otherVolumeDuckConfig: VolumeDuckConfig
    let otherMeetingsEnabled: () -> Bool
    let otherGoogleEnabled: () -> Bool
    let otherOnMeetingsToggle: (Bool) -> Void
    let otherOnGoogleToggle: (Bool) -> Void
    let privacyPreferences: PrivacyPreferences
    /// Applies the screenshot-protection toggle to the live island panel.
    let screenshotProtectionChanged: (Bool) -> Void
    /// What the Features screens read besides the view models; tests and
    /// previews replace it to show a Mac in another state.
    let featuresEnvironment: FeaturesEnvironment?
    /// Integrations' Coding tools; tests pass fixed answers.
    let codingTools: CodingToolsAccess?
    /// Owned here (not by `SettingsOtherView`) so the picker's options list
    /// survives tab switches — the detail pane recreates the tab views.
    @StateObject private var displayPickerViewModel = DisplayPickerViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedSidebarControl: String?

    /// The `otherVolumeDuckConfig` parameter is optional so callers without a
    /// pre-built config can pass `nil` and let `SettingsOtherView` construct its
    /// own (that init is also `@MainActor`-gated and builds fine at call time).
    init(
        permissionsViewModel: PermissionsSettingsViewModel,
        apiAndModelsViewModel: APIAndModelsViewModel,
        selection: SettingsWindowSelection,
        agentModeViewModel: AgentModeViewModel,
        toolboxDeps: ToolboxDeps = ToolboxDeps(),
        agentEnabled: @escaping () -> Bool = { false },
        onAgentToggle: @escaping (Bool) -> Void = { _ in },
        otherVolumeDuckConfig: VolumeDuckConfig? = nil,
        otherMeetingsEnabled: @escaping () -> Bool = { false },
        otherGoogleEnabled: @escaping () -> Bool = { false },
        otherOnMeetingsToggle: @escaping (Bool) -> Void = { _ in },
        otherOnGoogleToggle: @escaping (Bool) -> Void = { _ in },
        privacyPreferences: PrivacyPreferences? = nil,
        screenshotProtectionChanged: @escaping (Bool) -> Void = { _ in },
        featuresEnvironment: FeaturesEnvironment? = nil,
        codingTools: CodingToolsAccess? = nil
    ) {
        self.permissionsViewModel = permissionsViewModel
        self.apiAndModelsViewModel = apiAndModelsViewModel
        self.selection = selection
        self.agentModeViewModel = agentModeViewModel
        self.toolboxDeps = toolboxDeps
        self.agentEnabled = agentEnabled
        self.onAgentToggle = onAgentToggle
        self.otherVolumeDuckConfig = otherVolumeDuckConfig ?? VolumeDuckConfig()
        self.otherMeetingsEnabled = otherMeetingsEnabled
        self.otherGoogleEnabled = otherGoogleEnabled
        self.otherOnMeetingsToggle = otherOnMeetingsToggle
        self.otherOnGoogleToggle = otherOnGoogleToggle
        self.privacyPreferences = privacyPreferences ?? .shared
        self.screenshotProtectionChanged = screenshotProtectionChanged
        self.featuresEnvironment = featuresEnvironment
        self.codingTools = codingTools
    }

    /// The live environment: this window's own switches and Drop mode.
    private var liveFeaturesEnvironment: FeaturesEnvironment {
        FeaturesEnvironment(
            dropMode: toolboxDeps.currentDropMode,
            // The island owns the mode switch; Settings asks it to flip.
            setDropMode: { [toolboxDeps] mode in
                if toolboxDeps.currentDropMode() != mode { _ = toolboxDeps.toggleDropMode() }
            },
            language: toolboxDeps.currentLanguage,
            setLanguage: toolboxDeps.setLanguage,
            targetLanguage: toolboxDeps.currentTargetLanguage,
            setTargetLanguage: toolboxDeps.setTargetLanguage,
            volumeDuck: otherVolumeDuckConfig,
            openHoverPanel: toolboxDeps.openHoverPanel,
            agentOn: { AgentOtherSection.isOn(enabled: agentEnabled(),
                                              activeProvider: AgentProviderStore.shared.activeProvider) },
            meetingsOn: otherMeetingsEnabled,
            googleOn: otherGoogleEnabled,
            setAgent: { [agentModeViewModel, onAgentToggle] on in
                await AgentOtherSection.turn(on, viewModel: agentModeViewModel, settings: .shared,
                                             store: .shared, onAgentToggle: onAgentToggle)?.message
            },
            setMeetings: otherOnMeetingsToggle,
            setGoogle: otherOnGoogleToggle,
            openScreenshot: toolboxDeps.openScreenshot
        )
    }

    var body: some View {
        SidekeyAuroraWindow(title: AppBuildIdentity.current.settingsTitle, followsSystemAppearance: true) {
            settingsShell
        }
        .frame(minWidth: 960, minHeight: 560)
    }

    #if DEBUG
    /// How many times the shell was evaluated; tests read it to prove Lil
    /// Bro's steps leave the rest of the window alone.
    nonisolated(unsafe) static var shellEvaluations = 0
    #endif

    private var settingsShell: some View {
        #if DEBUG
        Self.shellEvaluations += 1
        #endif
        return HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(MacSettingsTheme.sep)
                .frame(width: 1)

            VStack(spacing: 0) {
                if let back = selection.backLink {
                    SettingsBackBar(title: back.title, action: { selection.goBack() })
                }
                detailPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scrollable tab list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: SettingsSidebarStyle.rowSpacing) {
                    ForEach(SettingsWindowTab.sidebarCases) { tab in
                        sidebarTabButton(tab)
                    }
                }
                .padding(.horizontal, SettingsSidebarStyle.horizontalPadding)
                .padding(.vertical, SettingsSidebarStyle.verticalPadding)
            }
            .frame(maxHeight: .infinity, alignment: .top)

            // Pinned project footer and Quit row stay visible even when the settings
            // tab list grows beyond the available window height.
            Rectangle()
                .fill(MacSettingsTheme.sep)
                .frame(height: 1)
                .padding(.horizontal, SettingsSidebarStyle.horizontalPadding)

            VStack(alignment: .leading, spacing: 4) {
                SettingsProjectFooter(identity: .current, updateController: AppState.shared.updateController,
                                      whatsNew: .shared)
                quitRow
            }
                .padding(.horizontal, SettingsSidebarStyle.horizontalPadding)
                .padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: SettingsSidebarStyle.width, alignment: .topLeading)
        .background(MacSettingsTheme.bgSidebar)
    }

    @ViewBuilder
    private func sidebarTabButton(_ tab: SettingsWindowTab) -> some View {
        let isHighlighted: Bool = {
            if case .tab(let t) = selection.highlightedTarget, t.sidebarHome == tab { return true }
            return false
        }()
        let isSelected = selection.selectedTab.sidebarHome == tab

        Button {
            selection.select(tab)
        } label: {
            HStack(spacing: 0) {
                Text(tab.title)
                    .font(.system(size: SettingsSidebarStyle.labelFontSize, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(SettingsSidebarStyle.labelMinimumScaleFactor)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected && !isHighlighted ? Color.white : MacSettingsTheme.text)
            .padding(.horizontal, SettingsSidebarStyle.buttonHorizontalPadding)
            .frame(height: SettingsSidebarStyle.rowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted
                          ? MacSettingsTheme.selection
                          : (isSelected
                             ? MacSettingsTheme.accentFill
                             : Color.clear))
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isHighlighted)
        }
        .buttonStyle(SettingsSidebarButtonStyle(isSelected: isSelected && !isHighlighted,
                                                focused: focusedSidebarControl == tab.id))
        .focused($focusedSidebarControl, equals: tab.id)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(tab.title)
    }

    private var quitRow: some View {
        let isHighlighted: Bool = {
            if case .quitRow = selection.highlightedTarget { return true }
            return false
        }()

        return Button {
            NSApp.terminate(nil)
        } label: {
            HStack(spacing: 0) {
                Text(AppBuildIdentity.current.quitActionTitle)
                    .font(.system(size: SettingsSidebarStyle.labelFontSize, weight: .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(MacSettingsTheme.red)
            .padding(.horizontal, SettingsSidebarStyle.buttonHorizontalPadding)
            .frame(height: SettingsSidebarStyle.rowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? Color.red.opacity(0.25) : Color.clear)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isHighlighted)
        }
        .buttonStyle(SettingsSidebarButtonStyle(focused: focusedSidebarControl == "quit"))
        .focused($focusedSidebarControl, equals: "quit")
        .accessibilityLabel(AppBuildIdentity.current.quitActionTitle)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selection.selectedTab {
        case .features:
            SettingsFeaturesView(
                selection: selection,
                models: apiAndModelsViewModel,
                permissions: permissionsViewModel,
                environment: featuresEnvironment ?? liveFeaturesEnvironment
            )
        case .apiAndModels:
            APIAndModelsView(viewModel: apiAndModelsViewModel, focusedFeature: $selection.focusedFeature,
                             initialSection: selection.requestedAPISection ?? .models)
                .onAppear { selection.requestedAPISection = nil }
        case .hotkeys:
            HotkeysSettingsView()
        case .permissions:
            SettingsPermissionsView(viewModel: permissionsViewModel)
        case .notes:
            HStack(spacing: 0) {
                if let notesController = selection.notesController {
                    MeetingsContentControllerView(controller: notesController)
                } else {
                    SettingsNotesUnavailableView()
                }
            }
        case .other:
            SettingsOtherView(
                displayPicker: displayPickerViewModel,
                privacyPreferences: privacyPreferences,
                screenshotProtectionChanged: screenshotProtectionChanged,
                open: { selection.select($0) }
            )
        case .agentMode, .notifications:
            // Never selected: `select` opens the Agent's or Notify's screen in Features.
            EmptyView()
        case .toolbox:
            ToolboxSettingsView(
                hoverStore: HoverLayoutStore.shared,
                selection: selection,
                deps: toolboxDeps
            )
        case .integrations:
            SettingsIntegrationsView(codingTools: codingTools ?? .shared)
        case .backup:
            SettingsBackupView(openIntegrations: { selection.select(.integrations) })
        }
    }
}

/// Compact rows retain full-area hover, press and keyboard-focus feedback.
// WHY: docs/DESIGN.md — Text-only Settings sidebar.
struct SettingsSidebarButtonStyle: ButtonStyle {
    var isSelected = false
    var focused = false

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, isSelected: isSelected, focused: focused)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let focused: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? (configuration.isPressed ? Color.black.opacity(0.12) : Color.white.opacity(0.10))
                              : (configuration.isPressed ? MacSettingsTheme.selection : MacSettingsTheme.hover.opacity(0.85)))
                        .opacity(isEnabled && (hovered || configuration.isPressed) ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
                        .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSelected ? Color.white : MacSettingsTheme.accent, lineWidth: 2)
                        .opacity(isEnabled && focused ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovered = isEnabled && $0 }
                .onChange(of: isEnabled) { _, enabled in if !enabled { hovered = false } }
                .onDisappear { hovered = false }
        }
    }
}

@MainActor
private struct MeetingsContentControllerView: NSViewControllerRepresentable {
    let controller: MeetingsContentController

    func makeNSViewController(context _: Context) -> MeetingsContentController {
        controller
    }

    func updateNSViewController(
        _ nsViewController: MeetingsContentController,
        context _: Context
    ) {
        _ = nsViewController
    }
}

@MainActor
private struct SettingsNotesUnavailableView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(MacSettingsTheme.text2)
            Text("Notes are not available")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text)
            Text("Meeting notes will appear here after the meetings store is ready.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MacSettingsTheme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class SettingsWindowSelection: ObservableObject {
    @Published var selectedTab: SettingsWindowTab
    @Published var notesController: MeetingsContentController?
    /// The feature row Keys & models scrolls to and highlights; the tab clears it once shown.
    @Published var focusedFeature: AIFeature?
    /// The tool Toolbox selects on appear (a `whytap://tool/` link); Toolbox clears it.
    @Published var focusedTool: HoverTool?
    /// The feature whose own screen Features shows; nil is the list.
    @Published var shownFeature: AppFeature?
    /// The part of Keys & models to open on next (API keys from a feature's
    /// screen); Keys & models takes it once and clears it.
    @Published var requestedAPISection: APIAndModelsSection?
    /// Non-nil for ~1s while a Toolbox navigate-tool click highlights a
    /// sidebar row or the Quit row. Cleared automatically by `setHighlight`.
    @Published private(set) var highlightedTarget: HoverNavigationTarget?
    var notesControllerProvider: (() -> MeetingsContentController?)?
    private var previousNonNotesTab: SettingsWindowTab
    private var highlightTask: Task<Void, Never>?

    init(selectedTab: SettingsWindowTab = .features) {
        let resolvedTab = selectedTab.resolved
        let availableTab = resolvedTab.isAvailable ? resolvedTab : SettingsWindowTab.defaultAvailable
        self.selectedTab = availableTab
        if let feature = selectedTab.featureScreen { shownFeature = feature }
        previousNonNotesTab = availableTab == .notes ? SettingsWindowTab.defaultAvailable : availableTab
    }

    func select(_ tab: SettingsWindowTab) {
        let resolvedTab = tab.resolved
        let availableTab = resolvedTab.isAvailable ? resolvedTab : SettingsWindowTab.defaultAvailable
        if availableTab == .notes {
            // The Notes entry always lands on the meeting
            // list, even if the controller was left mid-editor.
            ensureNotesController()?.showListScreen()
        } else {
            previousNonNotesTab = availableTab
        }
        // The sidebar's Features row is "Features home": back to the list.
        // A link to the old Agents or Notifications tab opens the Agent's or
        // Notify's own screen.
        if availableTab == .features { shownFeature = tab.featureScreen }
        selectedTab = availableTab
    }

    /// Opens a feature from the Features list: its own screen when it has one,
    /// otherwise the place its settings are shown today.
    // WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
    func open(_ feature: AppFeature) {
        switch FeatureCatalog.info(for: feature).place {
        case .screen:
            select(.features)
            shownFeature = feature
        case .tab(let tab):
            setHighlight(.tab(tab))
        case .tool(let tool):
            focus(tool)
        }
    }

    /// Where a tab outside the sidebar leads back to: the screen it was
    /// opened from (Meeting Notes for the notes, Hover for Toolbox) or General.
    // WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
    var backLink: (title: String, tab: SettingsWindowTab, feature: AppFeature?)? {
        switch selectedTab {
        case .notes: return ("Meeting Notes", .features, .meetings)
        case .toolbox: return ("Hover", .features, .hover)
        case .integrations, .backup: return ("General", .other, nil)
        case .features, .apiAndModels, .hotkeys, .permissions, .other, .agentMode, .notifications: return nil
        }
    }

    func goBack() {
        guard let back = backLink else { return }
        if let feature = back.feature { open(feature) } else { select(back.tab) }
    }

    /// Opens Keys & models on one feature's row.
    func focus(_ feature: AIFeature) {
        select(.apiAndModels)
        focusedFeature = feature
    }

    /// Opens Keys & models on API keys, where a key is added or replaced:
    /// "Add a key" and "Fix the key" on a feature's screen.
    // WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
    func showAPIKeys() {
        requestedAPISection = .keys
        select(.apiAndModels)
    }

    /// Opens Toolbox on one tool's pane without running its action.
    func focus(_ tool: HoverTool) {
        select(.toolbox)
        focusedTool = tool
    }

    func leaveNotes() {
        selectedTab = previousNonNotesTab
    }

    @discardableResult
    func ensureNotesController() -> MeetingsContentController? {
        if notesController == nil {
            notesController = notesControllerProvider?()
        }
        return notesController
    }

    /// Highlight `target` for ~1 second, then clear. When `target` is
    /// `.tab(t)`, also selects that tab. When `.quitRow`, doesn't change
    /// the selected tab.
    func setHighlight(_ target: HoverNavigationTarget) {
        if case .tab(let tab) = target {
            select(tab)
        }
        highlightTask?.cancel()
        highlightedTarget = target
        highlightTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            highlightedTarget = nil
        }
    }
}

enum SettingsSidebarStyle {
    static let width: CGFloat = 220
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 10
    static let buttonHorizontalPadding: CGFloat = 10
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 4
    static let labelFontSize: CGFloat = 13
    static let labelMinimumScaleFactor: CGFloat = 0.88

    static var labelAvailableWidth: CGFloat {
        width
            - horizontalPadding * 2
            - buttonHorizontalPadding * 2
    }
}

/// The "‹ General" line above a tab that is not in the sidebar, drawn like
/// the "‹ Features" link of a feature screen.
struct SettingsBackBar: View {
    let title: String
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text(title).font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(MacSettingsTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(MacButtonInteractionStyle(highlight: MacSettingsTheme.accent, focused: focused))
            .focused($focused)
            .accessibilityLabel("Back to \(title)")
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }
}
