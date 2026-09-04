import AppKit
import SwiftUI

/// Settings shell: one predictable home for every user-facing preference.
@MainActor
struct SettingsWindowView: View {
    @ObservedObject var permissionsViewModel: OnboardingPermissionsViewModel
    @ObservedObject var modelsViewModel: SettingsModelsViewModel
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
    /// Owned here (not by `SettingsOtherView`) so the picker's options list
    /// survives tab switches — the detail pane recreates the tab views.
    @StateObject private var displayPickerViewModel = DisplayPickerViewModel()

    /// The `otherVolumeDuckConfig` parameter is optional so callers without a
    /// pre-built config can pass `nil` and let `SettingsOtherView` construct its
    /// own (that init is also `@MainActor`-gated and builds fine at call time).
    init(
        permissionsViewModel: OnboardingPermissionsViewModel,
        modelsViewModel: SettingsModelsViewModel,
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
        screenshotProtectionChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.permissionsViewModel = permissionsViewModel
        self.modelsViewModel = modelsViewModel
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
    }

    var body: some View {
        SidekeyAuroraWindow(title: "Settings") {
            settingsShell
        }
    }

    private var settingsShell: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 560)
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scrollable tab list
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SettingsWindowTab.availableCases) { tab in
                    sidebarTabButton(tab)
                }
            }
            .padding(.horizontal, SettingsSidebarStyle.horizontalPadding)
            .padding(.vertical, SettingsSidebarStyle.verticalPadding)

            Spacer(minLength: 0)

            // Pinned support + Quit rows stay visible even when the settings
            // tab list grows beyond the available window height.
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .padding(.horizontal, SettingsSidebarStyle.horizontalPadding)

            VStack(alignment: .leading, spacing: 4) {
                learningCenterRow
                quitRow
            }
                .padding(.horizontal, SettingsSidebarStyle.horizontalPadding)
                .padding(.vertical, 10)
        }
        .frame(width: SettingsSidebarStyle.width, alignment: .topLeading)
    }

    @ViewBuilder
    private func sidebarTabButton(_ tab: SettingsWindowTab) -> some View {
        let isHighlighted: Bool = {
            if case .tab(let t) = selection.highlightedTarget, t == tab { return true }
            return false
        }()

        Button {
            selection.select(tab)
        } label: {
            HStack(spacing: SettingsSidebarStyle.iconTextSpacing) {
                SettingsSidebarIcon(tab: tab)
                Text(tab.title)
                    .font(.system(size: SettingsSidebarStyle.labelFontSize, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(SettingsSidebarStyle.labelMinimumScaleFactor)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selection.selectedTab == tab ? Color.white : MacSettingsTheme.text2)
            .padding(.horizontal, SettingsSidebarStyle.buttonHorizontalPadding)
            .frame(height: SettingsSidebarStyle.rowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted
                          ? Color.white.opacity(0.22)
                          : (selection.selectedTab == tab
                             ? MacSettingsTheme.accent
                             : Color.clear))
            )
            .animation(.easeOut(duration: 0.2), value: isHighlighted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
    }

    private var learningCenterRow: some View {
        Button {
            NSWorkspace.shared.open(HelpWindowContent.learningCenterURL)
        } label: {
            HStack(spacing: SettingsSidebarStyle.iconTextSpacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: SettingsSidebarIconStyle.cornerRadius,
                                     style: .continuous)
                        .fill(MacSettingsTheme.accent.opacity(0.24))
                    Image(systemName: "book.pages")
                        .font(.system(size: SettingsSidebarIconStyle.symbolFontSize, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color.white.opacity(0.88))
                }
                .frame(width: SettingsSidebarIconStyle.tileSize, height: SettingsSidebarIconStyle.tileSize)

                Text("FAQ & Learning")
                    .font(.system(size: SettingsSidebarStyle.labelFontSize, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(SettingsSidebarStyle.labelMinimumScaleFactor)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text3)
            }
            .foregroundStyle(MacSettingsTheme.text2)
            .padding(.horizontal, SettingsSidebarStyle.buttonHorizontalPadding)
            .frame(height: SettingsSidebarStyle.rowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open FAQ and Learning Center")
    }

    private var quitRow: some View {
        let isHighlighted: Bool = {
            if case .quitRow = selection.highlightedTarget { return true }
            return false
        }()

        return Button {
            NSApp.terminate(nil)
        } label: {
            HStack(spacing: SettingsSidebarStyle.iconTextSpacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: SettingsSidebarIconStyle.cornerRadius,
                                     style: .continuous)
                        .fill(Color(red: 0.55, green: 0.10, blue: 0.10))
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: SettingsSidebarIconStyle.symbolFontSize, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: SettingsSidebarIconStyle.tileSize, height: SettingsSidebarIconStyle.tileSize)

                Text("Quit Whytap")
                    .font(.system(size: SettingsSidebarStyle.labelFontSize, weight: .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
            .padding(.horizontal, SettingsSidebarStyle.buttonHorizontalPadding)
            .frame(height: SettingsSidebarStyle.rowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? Color.red.opacity(0.25) : Color.clear)
            )
            .animation(.easeOut(duration: 0.2), value: isHighlighted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quit Whytap")
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selection.selectedTab {
        case .models:
            SettingsModelsView(viewModel: modelsViewModel)
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
                volumeDuckConfig: otherVolumeDuckConfig,
                meetingsEnabled: otherMeetingsEnabled,
                googleEnabled: otherGoogleEnabled,
                onMeetingsToggle: otherOnMeetingsToggle,
                onGoogleToggle: otherOnGoogleToggle,
                onMeetingRecordToggle: {
                    Task { @MainActor in
                        await AppState.shared.meetingsCoordinator?.toggleManualRecording()
                    }
                },
                privacyPreferences: privacyPreferences,
                screenshotProtectionChanged: screenshotProtectionChanged
            )
        case .agentMode:
            AgentModeView(
                viewModel: agentModeViewModel,
                settings: AgentSettingsStore.shared,
                store: AgentProviderStore.shared,
                agentEnabled: agentEnabled,
                onAgentToggle: onAgentToggle
            )
        case .toolbox:
            ToolboxSettingsView(
                hoverStore: HoverLayoutStore.shared,
                selection: selection,
                deps: toolboxDeps
            )
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
                .foregroundStyle(.white.opacity(0.62))
            Text("Notes are not available")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
            Text("Meeting notes will appear here after the meetings store is ready.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class SettingsWindowSelection: ObservableObject {
    @Published var selectedTab: SettingsWindowTab
    @Published var notesController: MeetingsContentController?
    /// Non-nil for ~1s while a Toolbox navigate-tool click highlights a
    /// sidebar row or the Quit row. Cleared automatically by `setHighlight`.
    @Published private(set) var highlightedTarget: HoverNavigationTarget?
    var notesControllerProvider: (() -> MeetingsContentController?)?
    private var previousNonNotesTab: SettingsWindowTab
    private var highlightTask: Task<Void, Never>?

    init(selectedTab: SettingsWindowTab = .models) {
        let availableTab = selectedTab.isAvailable ? selectedTab : SettingsWindowTab.defaultAvailable
        self.selectedTab = availableTab
        previousNonNotesTab = availableTab == .notes ? SettingsWindowTab.defaultAvailable : availableTab
    }

    func select(_ tab: SettingsWindowTab) {
        let availableTab = tab.isAvailable ? tab : SettingsWindowTab.defaultAvailable
        if availableTab == .notes {
            // Sidebar Notes button = "Notes home": always land on the meeting
            // list, even if the controller was left mid-editor.
            ensureNotesController()?.showListScreen()
        } else {
            previousNonNotesTab = availableTab
        }
        selectedTab = availableTab
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
    static let verticalPadding: CGFloat = 14
    static let buttonHorizontalPadding: CGFloat = 10
    static let iconTextSpacing: CGFloat = 9
    static let rowHeight: CGFloat = 34
    static let labelFontSize: CGFloat = 13
    static let labelMinimumScaleFactor: CGFloat = 0.88

    static var labelAvailableWidth: CGFloat {
        width
            - horizontalPadding * 2
            - buttonHorizontalPadding * 2
            - SettingsSidebarIconStyle.tileSize
            - iconTextSpacing
    }
}

enum SettingsSidebarIconStyle {
    static let tileSize: CGFloat = 24
    static let cornerRadius: CGFloat = 6
    static let symbolFontSize: CGFloat = 13
}

@MainActor
private struct SettingsSidebarIcon: View {
    let tab: SettingsWindowTab

    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: SettingsSidebarIconStyle.cornerRadius,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.110, green: 0.110, blue: 0.133),
                        Color(red: 0.075, green: 0.075, blue: 0.094),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: SettingsSidebarIconStyle.cornerRadius,
                    style: .continuous
                )
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )

            iconArtwork
                .frame(
                    width: SettingsSidebarIconStyle.tileSize,
                    height: SettingsSidebarIconStyle.tileSize
                )
        }
        .frame(
            width: SettingsSidebarIconStyle.tileSize,
            height: SettingsSidebarIconStyle.tileSize
        )
    }

    @ViewBuilder
    private var iconArtwork: some View {
        if let resourceName = tab.pdfResourceName,
           let nsImage = IslandControlIcon.image(named: resourceName) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: tab.fallbackSystemImageName)
                .font(.system(size: SettingsSidebarIconStyle.symbolFontSize, weight: .regular))
                .symbolRenderingMode(.monochrome)
        }
    }
}
