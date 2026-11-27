import AppKit
import SwiftUI
import UserNotifications

/// Owns the Settings `NSWindow`. Reuses the same window across activations —
/// `show()` brings the existing window to front instead of constructing a
/// new one each time.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let didStartVisit = Notification.Name("SettingsWindowController.didStartVisit")
    private let permissionsViewModel: PermissionsSettingsViewModel
    private let apiAndModelsViewModel: APIAndModelsViewModel
    let selection = SettingsWindowSelection()
    private var toolboxDeps = ToolboxDeps()
    /// Deps threaded into the Other tab via `configureOtherDeps(...)`.
    /// Capability seeds are live getters so `SettingsOtherView` reads the
    /// current value on every appear (a static seed would go stale on revisit).
    private var otherVolumeDuckConfig = VolumeDuckConfig()
    private var agentEnabled: () -> Bool = { false }
    private var otherMeetingsEnabled: () -> Bool = { false }
    private var otherGoogleEnabled: () -> Bool = { false }
    private var onAgentToggle: (Bool) -> Void = { _ in }
    private var otherOnMeetingsToggle: (Bool) -> Void = { _ in }
    private var otherOnGoogleToggle: (Bool) -> Void = { _ in }
    private let privacyPreferences: PrivacyPreferences
    private let screenshotProtectionChanged: (Bool) -> Void

    var selectedTab: SettingsWindowTab {
        selection.selectedTab
    }

    init(
        privacyPreferences: PrivacyPreferences? = nil,
        screenshotProtectionChanged: @escaping (Bool) -> Void = { _ in },
        notesControllerProvider: @escaping () -> MeetingsContentController? = { nil }
    ) {
        let permissionsViewModel = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false)
        let apiAndModelsViewModel = APIAndModelsViewModel()
        // Created at launch and kept for the app's life; the window opens later.
        apiAndModelsViewModel.setPresented(false)
        self.permissionsViewModel = permissionsViewModel
        self.apiAndModelsViewModel = apiAndModelsViewModel
        self.privacyPreferences = privacyPreferences ?? .shared
        self.screenshotProtectionChanged = screenshotProtectionChanged


        selection.notesControllerProvider = { notesControllerProvider() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whytap Settings"
        // Keep the controller as the source of truth — destroying the
        // window on close would invalidate the `@ObservedObject` binding
        // and force a fresh fetch on every reopen.
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.isEnabled = true
        SidekeyWindowChrome.configureHoverOverlayPolicy(window)
        SidekeyWindowChrome.configure(window)
        // SidekeyWindowChrome.configure sets isMovableByWindowBackground=true
        // for chromeless windows, but Settings has drag-and-drop catalog
        // tiles — without this override any drag gesture moves the window
        // instead of starting the tile drag.
        window.isMovableByWindowBackground = false

        super.init(window: window)
        window.delegate = self
        refreshRootView()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController only supports programmatic init.")
    }

    /// Bring the window forward and refresh the selected tab.
    func show(tab: SettingsWindowTab = .apiAndModels, feature: AIFeature? = nil) {
        if window?.isVisible != true {
            NotificationCenter.default.post(name: Self.didStartVisit, object: self)
        }
        // Up to date before the window draws its first frame.
        apiAndModelsViewModel.setPresented(true)
        if let feature {
            selection.focus(feature)
        } else {
            selection.select(tab)
        }
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            SidekeyWindowChrome.centerOnMainScreen(window)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            SidekeyWindowChrome.centerOnMainScreen(window)
            SidekeyWindowChrome.centerOnMainScreenAfterNextLayout(window)
        }
        Task { await loadIfNeeded(tab: selection.selectedTab) }
    }

    func windowWillClose(_ notification: Notification) {
        toolboxDeps.endToolSessions()
        // WHY: .project-docs/decisions/2026-11-27-settings-models-recompute-while-hidden.md
        apiAndModelsViewModel.setPresented(false)
    }

    func configure(toolboxDeps: ToolboxDeps) {
        self.toolboxDeps = toolboxDeps
        refreshRootView()
    }

    /// Wire the Other-tab (volume-duck + capability toggles) into the Settings
    /// shell. The capability seeds are read live via getters at view-appear
    /// time (not here), so revisiting the tab always reflects the current
    /// flag value. The toggle closures route live flips back to the cache.
    func configureOtherDeps(
        onAgentToggle: @escaping (Bool) -> Void,
        onMeetingsToggle: @escaping (Bool) -> Void,
        onGoogleToggle: @escaping (Bool) -> Void
    ) {
        self.otherVolumeDuckConfig = VolumeDuckConfig()
        self.agentEnabled = { UserPreferencesCache.shared.currentAgentEnabled }
        self.otherMeetingsEnabled = { UserPreferencesCache.shared.currentMeetingsEnabled }
        self.otherGoogleEnabled = { UserPreferencesCache.shared.currentGoogleEnabled }
        self.onAgentToggle = onAgentToggle
        self.otherOnMeetingsToggle = onMeetingsToggle
        self.otherOnGoogleToggle = onGoogleToggle
        refreshRootView()
    }

    /// True while a note is open for editing in the Meetings tab.
    var isEditingNote: Bool { selection.notesController?.isEditingNote == true }

    func selectNoteMeeting(id: UUID) {
        selection.select(.notes)
        selection.ensureNotesController()?.selectMeeting(id: id)
    }

    private func makeRootView() -> SettingsWindowView {
        SettingsWindowView(
            permissionsViewModel: permissionsViewModel,
            apiAndModelsViewModel: apiAndModelsViewModel,
            selection: selection,
            toolboxDeps: toolboxDeps,
            agentEnabled: agentEnabled,
            onAgentToggle: onAgentToggle,
            otherVolumeDuckConfig: otherVolumeDuckConfig,
            otherMeetingsEnabled: otherMeetingsEnabled,
            otherGoogleEnabled: otherGoogleEnabled,
            otherOnMeetingsToggle: otherOnMeetingsToggle,
            otherOnGoogleToggle: otherOnGoogleToggle,
            privacyPreferences: privacyPreferences,
            screenshotProtectionChanged: screenshotProtectionChanged
        )
    }

    private func refreshRootView() {
        guard let window else { return }
        if let hosting = window.contentViewController as? NSHostingController<SettingsWindowView> {
            hosting.rootView = makeRootView()
        } else {
            window.contentViewController = NSHostingController(rootView: makeRootView())
        }
    }

    private func loadIfNeeded(tab: SettingsWindowTab) async {
        switch tab {
        case .features:
            // The Features views refresh their own models and permissions.
            break
        case .apiAndModels:
            await apiAndModelsViewModel.onAppear()
        case .hotkeys:
            break
        case .permissions:
            permissionsViewModel.refresh()
        case .notes:
            selection.ensureNotesController()?.refreshOnShow()
        case .agentMode, .notifications:
            break
        case .toolbox:
            break
        case .integrations:
            break
        case .backup:
            break
        case .other:
            break
        }
    }

}
