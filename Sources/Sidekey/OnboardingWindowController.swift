import AppKit
import SwiftUI

/// Hosts the native SwiftUI onboarding flow in a 960×600 regular app
/// window. AppDelegate promotes Whytap to a Dock-visible app while the
/// flow is active, then returns the product runtime to accessory mode
/// after onboarding closes or completes.
///
/// The actual screens live in `Sources/Sidekey/Onboarding/`. This
/// controller is intentionally thin — it owns the NSWindow lifecycle
/// and the completion callback, nothing else.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private static let contentSize = NSSize(
        width: OnboardingTheme.canvasWidth,
        height: OnboardingTheme.canvasHeight
    )

    private let lifecycleEvents = OnboardingLifecycleEvents()
    private var onComplete: () -> Void
    private let autoComplete: Bool
    private let onClosed: () -> Void
    private(set) var currentStep: OnboardingFlowStep
    private var isSteppedAsideForExternalHandoff = false
    private var didNotifyClosed = false

    init(
        onComplete: @escaping () -> Void,
        autoComplete: Bool = true,
        initialStep: OnboardingFlowStep = .permissions,
        onClosed: @escaping () -> Void = {},
        onTryStepRuntimeRequired: @escaping () -> Void = {},
        onTryStepRuntimeNoLongerRequired: @escaping () -> Void = {},
        onCapabilityToggle: @escaping (OnboardingSkillCapability, Bool) -> Void = { _, _ in }
    ) {
        self.onComplete = onComplete
        self.autoComplete = autoComplete
        self.onClosed = onClosed
        self.currentStep = initialStep

        // Hold a weak reference to self before super.init so the flow's
        // completion closure can dismiss the window — we cannot use
        // `self` inside the hosting controller's closure before
        // `super.init` runs.
        weak var weakController: OnboardingWindowController?
        let hosting = NSHostingController(
            rootView: OnboardingFlowView(
                initialStep: initialStep,
                lifecycleEvents: lifecycleEvents,
                onTryStepRuntimeRequired: onTryStepRuntimeRequired,
                onTryStepRuntimeNoLongerRequired: onTryStepRuntimeNoLongerRequired,
                onStepChanged: { step in
                    weakController?.currentStep = step
                    // The Try-Agent step renders the agent's reply in its own
                    // onboarding card; suppress the island's answer panel there
                    // so the same answer is not duplicated up top. (The runtime
                    // is already armed by this point — `advance` arms it before
                    // emitting the step change — so `agentFlow` is the live store.)
                    IslandPanel.shared.agentFlow.answerPanelSuppressed = (step == .tryAgent)
                },
                onCapabilityToggle: onCapabilityToggle,
                onExternalPermissionHandoff: {
                    weakController?.stepAsideForExternalHandoff()
                },
                onExternalPermissionReturn: {
                    weakController?.restoreAfterExternalHandoffIfNeeded()
                },
                onFinish: { weakController?.finish() }
            )
        )
        _ = autoComplete  // accepted for back-compat; no longer used

        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.contentSize.width,
                height: Self.contentSize.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Whytap"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .normal
        window.collectionBehavior = [.managed, .fullScreenNone]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(
            red: 0.047, green: 0.047, blue: 0.063, alpha: 1.0
        )
        SidekeyWindowChrome.configure(window)

        super.init(window: window)
        window.delegate = self
        weakController = self
    }

    required init?(coder: NSCoder) {
        fatalError("OnboardingWindowController only supports programmatic init.")
    }

    override func close() {
        stopAudioDemos()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Safety net: close() should already stop demos, but AppKit can
        // also deliver delegate close paths directly.
        stopAudioDemos()
        guard !didNotifyClosed else { return }
        didNotifyClosed = true
        onClosed()
    }

    func show() {
        guard let window else { return }
        didNotifyClosed = false
        window.level = .normal
        Self.pinContentSize(window)
        SidekeyWindowChrome.centerOnMainScreen(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Self.pinContentSize(window)
        SidekeyWindowChrome.centerOnMainScreen(window)
    }

    /// Let System Settings own the next user decision without making
    /// onboarding feel like it vanished. During the handoff we drop to
    /// normal level and order behind the active surface instead of hiding
    /// the window entirely.
    func stepAsideForExternalHandoff() {
        guard let window else { return }
        isSteppedAsideForExternalHandoff = true
        window.level = .normal
        window.orderBack(nil)
    }

    func restoreAfterExternalHandoffIfNeeded() {
        guard isSteppedAsideForExternalHandoff else { return }
        restoreAfterExternalHandoff()
    }

    /// Restore onboarding above whatever surface the user visited.
    func restoreAfterExternalHandoff() {
        guard let window else { return }
        isSteppedAsideForExternalHandoff = false
        window.level = .normal
        Self.pinContentSize(window)
        SidekeyWindowChrome.centerOnMainScreen(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Self.pinContentSize(window)
        SidekeyWindowChrome.centerOnMainScreen(window)
    }

    /// AppDelegate calls this when re-using the same controller across
    /// a "manual open" gesture so the completion target updates without
    /// re-creating the window.
    func updateOnComplete(_ onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    private func finish() {
        OnboardingResumeStore.clear()
        OnboardingResumeStore.markOnboardingCompleted()
        onComplete()
    }

    private func stopAudioDemos() {
        lifecycleEvents.stopAudio()
    }

    private static func pinContentSize(_ window: NSWindow) {
        window.setContentSize(contentSize)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
