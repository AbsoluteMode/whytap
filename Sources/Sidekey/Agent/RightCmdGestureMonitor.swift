import AppKit
import CoreGraphics
import Foundation

final class RightCmdGestureMonitor: RightCmdGestureMonitoring {
    typealias Callback = () -> Void
    typealias SnapshotCallback = (FocusSnapshot?) -> Void

    static let gestureThresholdMs: TimeInterval = 0.2

    private static let monitoredEvents: NSEvent.EventTypeMask = [
        .flagsChanged,
        .keyDown,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown
    ]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var holdTimer: Timer?
    private var googleGraceTimer: Timer?
    private var comboMonitors: [HotkeyShortcutMonitor] = []
    private var comboCallbacks: AgentComboCallbacks?
    private let stateMachine: RightCmdGestureStateMachine

    init(activationKey: HotkeyModifierKey = HotkeyConfiguration.defaults.agentTextKey) {
        self.stateMachine = RightCmdGestureStateMachine(
            captureSnapshot: FocusSnapshot.capture,
            activationKey: activationKey
        )
    }

    deinit {
        stop()
    }

    func start(
        onSnapshot: @escaping SnapshotCallback = { _ in },
        onTap: @escaping Callback,
        onHoldStart: @escaping Callback,
        onHoldEnd: @escaping Callback,
        onCancel: @escaping Callback
    ) {
        start(
            onSnapshot: onSnapshot,
            onTextTap: onTap,
            onVoiceTap: {},
            onVoiceHoldStart: onHoldStart,
            onVoiceHoldEnd: onHoldEnd,
            onCancel: onCancel
        )
    }

    func start(
        onSnapshot: @escaping SnapshotCallback = { _ in },
        onTextTap: @escaping Callback,
        onVoiceTap: @escaping Callback,
        onVoiceHoldStart: @escaping Callback,
        onVoiceHoldEnd: @escaping Callback,
        onCancel: @escaping Callback,
        onGoogleTextTap: @escaping Callback = {},
        onGoogleVoiceTap: @escaping Callback = {},
        onGoogleHoldStart: @escaping Callback = {},
        onGoogleHoldEnd: @escaping Callback = {},
        onGoogleCancel: @escaping Callback = {}
    ) {
        stop()

        stateMachine.configure(
            onSnapshot: onSnapshot,
            onTap: onTextTap,
            onVoiceTap: onVoiceTap,
            onHoldStart: onVoiceHoldStart,
            onHoldEnd: onVoiceHoldEnd,
            onCancel: onCancel,
            onScheduleThreshold: { [weak self] in
                self?.scheduleHoldTimer()
            },
            onCancelThreshold: { [weak self] in
                self?.cancelHoldTimer()
            },
            onHotkeyKeyHeldChanged: { key, isHeld in
                Task { @MainActor in
                    AppState.shared.setHotkeyModifierKey(key, held: isHeld)
                }
            },
            onGoogleTextTap: onGoogleTextTap,
            onGoogleVoiceTap: onGoogleVoiceTap,
            onGoogleHoldStart: onGoogleHoldStart,
            onGoogleHoldEnd: onGoogleHoldEnd,
            onGoogleCancel: onGoogleCancel,
            onScheduleGoogleGrace: { [weak self] in
                self?.scheduleGoogleGraceTimer()
            },
            onCancelGoogleGrace: { [weak self] in
                self?.cancelGoogleGraceTimer()
            }
        )
        comboCallbacks = AgentComboCallbacks(
            onSnapshot: onSnapshot,
            onTextTap: onTextTap,
            onVoiceTap: onVoiceTap,
            onVoiceHoldStart: onVoiceHoldStart,
            onVoiceHoldEnd: onVoiceHoldEnd
        )

        // Two monitors run in parallel:
        //
        // * Global — sees events sent to *other* apps. Requires Accessibility
        //   (granted via AXIsProcessTrustedWithOptions). Fires while Sidekey
        //   is in the background, which is the steady state because we are
        //   LSUIElement.
        // * Local — sees events sent to *our own* app. Required because once
        //   the text-input panel calls `NSApp.activate(ignoringOtherApps:)`,
        //   subsequent R-Cmd flagsChanged go through the local event queue
        //   and the global monitor never sees them. Without this, the second
        //   R-Cmd tap (for toggle-close) is silently dropped.
        //
        // The state machine is idempotent on duplicate flagsChanged with the
        // same flag bits, so even an edge case where both monitors observe
        // the same event yields one logical transition.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: Self.monitoredEvents
        ) { [weak self] event in
            self?.handleNSEvent(event)
        }
        if globalMonitor == nil {
            FileHandle.standardError.write(
                Data("RightCmdGestureMonitor failed to install NSEvent global monitor. Accessibility permission likely missing.\n".utf8)
            )
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: Self.monitoredEvents
        ) { [weak self] event in
            self?.handleNSEvent(event)
            // Never consume — the event must still reach our own AppKit /
            // SwiftUI responders (text view typing, send-button clicks).
            return event
        }
        restartAgentComboMonitors()
    }

    func stop() {
        cancelHoldTimer()
        stopAgentComboMonitors()
        comboCallbacks = nil
        stateMachine.reset()

        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        localMonitor = nil
    }

    var hasLocalMonitorForTesting: Bool { localMonitor != nil }
    var hasGlobalMonitorForTesting: Bool { globalMonitor != nil }

    func setActivationKey(_ key: HotkeyModifierKey) {
        let configuration = HotkeyConfiguration(
            agentTextKey: key,
            agentVoiceKey: key,
            agentVoiceGesture: .hold,
            // The Right-Cmd monitor only consults the agent key; the Drop slot
            // is a required initializer arg it never reads. Pass `.optionSlash`
            // literally rather than `defaults.dropVoiceTapCombo` — the default
            // Drop shortcut is now `.holdSpace` (no combo), so the convenience
            // combo initializer here just needs any placeholder combo.
            dropVoiceTapCombo: .optionSlash
        )
        setConfiguration(configuration)
    }

    func setConfiguration(_ configuration: HotkeyConfiguration) {
        guard stateMachine.configuration != configuration else { return }
        cancelHoldTimer()
        stateMachine.reset()
        stateMachine.configuration = configuration
        restartAgentComboMonitors()
    }

    private func handleNSEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            guard let cgEvent = event.cgEvent else { return }
            _ = stateMachine.handle(
                .flagsChanged(rawFlags: cgEvent.flags.rawValue)
            )
        case .keyDown:
            guard let cgEvent = event.cgEvent else { return }
            _ = stateMachine.handle(
                .keyDown(
                    keyCode: cgEvent.getIntegerValueField(.keyboardEventKeycode),
                    rawFlags: cgEvent.flags.rawValue
                )
            )
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            _ = stateMachine.handle(.mouseDown)
        default:
            break
        }
    }

    private func scheduleHoldTimer() {
        cancelHoldTimer()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.gestureThresholdMs, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                _ = self?.stateMachine.handle(.thresholdElapsed)
            }
        }
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    /// Variant A grace: how long a Google hold-start is parked after the
    /// threshold so a combo keypress (⌥M) can silently veto it. Short enough
    /// to be imperceptible on a deliberate Google hold, long enough to cover
    /// the natural ⌥…M typing gap.
    static let googleGraceMs: TimeInterval = 0.12

    private func scheduleGoogleGraceTimer() {
        cancelGoogleGraceTimer()
        googleGraceTimer = Timer.scheduledTimer(withTimeInterval: Self.googleGraceMs, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                _ = self?.stateMachine.handle(.googleGraceElapsed)
            }
        }
    }

    private func cancelGoogleGraceTimer() {
        googleGraceTimer?.invalidate()
        googleGraceTimer = nil
    }

    private func restartAgentComboMonitors() {
        stopAgentComboMonitors()
        guard let comboCallbacks else { return }

        let registrations = Self.agentComboRegistrations(
            for: stateMachine.configuration,
            callbacks: comboCallbacks
        )
        for registration in registrations {
            let monitor = HotkeyShortcutMonitor(
                shortcut: .combo(registration.combo),
                hotKeyIDValue: registration.hotKeyIDValue,
                onHotkey: { registration.controller.pressed() },
                onHotkeyReleased: { registration.controller.released() }
            )
            do {
                try monitor.start()
                comboMonitors.append(monitor)
            } catch {
                FileHandle.standardError.write(
                    Data("RightCmdGestureMonitor failed to register agent combo hotkey: \(error)\n".utf8)
                )
            }
        }
    }

    private func stopAgentComboMonitors() {
        comboMonitors.forEach { $0.stop() }
        comboMonitors.removeAll()
    }

    private static func agentComboRegistrations(
        for configuration: HotkeyConfiguration,
        callbacks: AgentComboCallbacks
    ) -> [AgentComboRegistration] {
        var registrations: [HotkeyTapCombo: AgentComboRegistrationDraft] = [:]

        if let textCombo = configuration.agentTextShortcut.combo {
            registrations[textCombo, default: AgentComboRegistrationDraft(combo: textCombo)]
                .tapAction = .text
        }

        if let voiceCombo = configuration.agentVoiceShortcut.combo {
            var draft = registrations[voiceCombo, default: AgentComboRegistrationDraft(combo: voiceCombo)]
            switch configuration.agentVoiceGesture {
            case .tap:
                if draft.tapAction == nil {
                    draft.tapAction = .voice
                }
            case .hold:
                draft.holdEnabled = true
            }
            registrations[voiceCombo] = draft
        }

        return registrations.values
            .sorted { $0.hotKeyIDValue < $1.hotKeyIDValue }
            .map { draft in
                AgentComboRegistration(
                    combo: draft.combo,
                    hotKeyIDValue: draft.hotKeyIDValue,
                    controller: AgentComboGestureController(
                        tapAction: draft.tapAction,
                        holdEnabled: draft.holdEnabled,
                        captureSnapshot: FocusSnapshot.capture,
                        onSnapshot: callbacks.onSnapshot,
                        onTextTap: callbacks.onTextTap,
                        onVoiceTap: callbacks.onVoiceTap,
                        onHoldStart: callbacks.onVoiceHoldStart,
                        onHoldEnd: callbacks.onVoiceHoldEnd
                    )
                )
            }
    }

    private struct AgentComboCallbacks {
        let onSnapshot: SnapshotCallback
        let onTextTap: Callback
        let onVoiceTap: Callback
        let onVoiceHoldStart: Callback
        let onVoiceHoldEnd: Callback
    }

    private struct AgentComboRegistration {
        let combo: HotkeyTapCombo
        let hotKeyIDValue: UInt32
        let controller: AgentComboGestureController
    }

    private struct AgentComboRegistrationDraft {
        let combo: HotkeyTapCombo
        var tapAction: AgentComboGestureController.TapAction?
        var holdEnabled = false

        var hotKeyIDValue: UInt32 {
            tapAction == .text ? CarbonHotkeyMonitor.agentTextHotKeyID : CarbonHotkeyMonitor.agentVoiceHotKeyID
        }
    }
}

protocol RightCmdGestureMonitoring: AnyObject {
    func start(
        onSnapshot: @escaping RightCmdGestureMonitor.SnapshotCallback,
        onTap: @escaping RightCmdGestureMonitor.Callback,
        onHoldStart: @escaping RightCmdGestureMonitor.Callback,
        onHoldEnd: @escaping RightCmdGestureMonitor.Callback,
        onCancel: @escaping RightCmdGestureMonitor.Callback
    )
    func stop()
}

final class AgentComboGestureController {
    enum TapAction: Equatable {
        case text
        case voice
    }

    private enum State {
        case idle
        case pending
        case holding
    }

    private let tapAction: TapAction?
    private let holdEnabled: Bool
    private let captureSnapshot: () -> FocusSnapshot?
    private let onSnapshot: RightCmdGestureMonitor.SnapshotCallback
    private let onTextTap: RightCmdGestureMonitor.Callback
    private let onVoiceTap: RightCmdGestureMonitor.Callback
    private let onHoldStart: RightCmdGestureMonitor.Callback
    private let onHoldEnd: RightCmdGestureMonitor.Callback
    private let holdThreshold: TimeInterval
    private var state: State = .idle
    private var holdTimer: Timer?

    init(
        tapAction: TapAction?,
        holdEnabled: Bool,
        holdThreshold: TimeInterval = RightCmdGestureMonitor.gestureThresholdMs,
        captureSnapshot: @escaping () -> FocusSnapshot?,
        onSnapshot: @escaping RightCmdGestureMonitor.SnapshotCallback,
        onTextTap: @escaping RightCmdGestureMonitor.Callback,
        onVoiceTap: @escaping RightCmdGestureMonitor.Callback,
        onHoldStart: @escaping RightCmdGestureMonitor.Callback,
        onHoldEnd: @escaping RightCmdGestureMonitor.Callback
    ) {
        self.tapAction = tapAction
        self.holdEnabled = holdEnabled
        self.holdThreshold = holdThreshold
        self.captureSnapshot = captureSnapshot
        self.onSnapshot = onSnapshot
        self.onTextTap = onTextTap
        self.onVoiceTap = onVoiceTap
        self.onHoldStart = onHoldStart
        self.onHoldEnd = onHoldEnd
    }

    convenience init(
        captureSnapshot: @escaping () -> FocusSnapshot?,
        tapAction: TapAction?,
        holdEnabled: Bool,
        onSnapshot: @escaping RightCmdGestureMonitor.SnapshotCallback,
        onTextTap: @escaping RightCmdGestureMonitor.Callback,
        onVoiceTap: @escaping RightCmdGestureMonitor.Callback,
        onVoiceHoldStart: @escaping RightCmdGestureMonitor.Callback,
        onVoiceHoldEnd: @escaping RightCmdGestureMonitor.Callback,
        onCancel: @escaping RightCmdGestureMonitor.Callback
    ) {
        self.init(
            tapAction: tapAction,
            holdEnabled: holdEnabled,
            captureSnapshot: captureSnapshot,
            onSnapshot: onSnapshot,
            onTextTap: onTextTap,
            onVoiceTap: onVoiceTap,
            onHoldStart: onVoiceHoldStart,
            onHoldEnd: onVoiceHoldEnd
        )
    }

    deinit {
        holdTimer?.invalidate()
    }

    func pressed() {
        guard state == .idle else { return }
        onSnapshot(captureSnapshot())
        state = .pending
        if holdEnabled {
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
                self?.thresholdElapsed()
            }
        }
    }

    func released() {
        holdTimer?.invalidate()
        holdTimer = nil

        switch state {
        case .idle:
            break
        case .pending:
            state = .idle
            switch tapAction {
            case .text:
                onTextTap()
            case .voice:
                onVoiceTap()
            case nil:
                break
            }
        case .holding:
            state = .idle
            onHoldEnd()
        }
    }

    func thresholdElapsedForTesting() {
        thresholdElapsed()
    }

    private func thresholdElapsed() {
        guard state == .pending, holdEnabled else { return }
        state = .holding
        onHoldStart()
    }
}

final class RightCmdGestureStateMachine {
    enum State: Equatable {
        case idle
        case pending
        case holding
        /// Google-only: threshold elapsed, but the hold-start is parked for a
        /// short grace window so a combo keypress (default ⌥M rides the same
        /// right Option) can silently veto it before any UI appears.
        case googleGraceWaiting
        case cancelledWaitingForRelease
    }

    enum Input: Equatable {
        case flagsChanged(rawFlags: UInt64)
        case keyDown(keyCode: Int64, rawFlags: UInt64)
        case mouseDown
        case thresholdElapsed
        /// The short post-threshold GRACE window for a Google hold elapsed —
        /// no combo keypress vetoed it, so the recording may actually start
        /// (Variant A, founder-approved 2026-07-06).
        case googleGraceElapsed
    }

    enum EventDisposition: Equatable {
        case passThrough
    }

    enum GestureAction: Equatable { case agent, google }

    static let escapeKeyCode: Int64 = 53

    private(set) var state: State = .idle
    var configuration: HotkeyConfiguration
    private let captureSnapshot: () -> FocusSnapshot?
    private var activeKey: HotkeyModifierKey?
    private var pendingTapAction: TapAction?
    private var pendingHoldEnabled = false
    private var pendingAction: GestureAction = .agent
    private var onSnapshot: RightCmdGestureMonitor.SnapshotCallback = { _ in }
    private var onTap: RightCmdGestureMonitor.Callback = {}
    private var onVoiceTap: RightCmdGestureMonitor.Callback = {}
    private var onHoldStart: RightCmdGestureMonitor.Callback = {}
    private var onHoldEnd: RightCmdGestureMonitor.Callback = {}
    private var onCancel: RightCmdGestureMonitor.Callback = {}
    private var onScheduleThreshold: RightCmdGestureMonitor.Callback = {}
    private var onCancelThreshold: RightCmdGestureMonitor.Callback = {}
    private var onHotkeyKeyHeldChanged: (HotkeyModifierKey, Bool) -> Void = { _, _ in }
    private var onGoogleTextTap: RightCmdGestureMonitor.Callback = {}
    private var onGoogleVoiceTap: RightCmdGestureMonitor.Callback = {}
    private var onGoogleHoldStart: RightCmdGestureMonitor.Callback = {}
    private var onGoogleHoldEnd: RightCmdGestureMonitor.Callback = {}
    private var onGoogleCancel: RightCmdGestureMonitor.Callback = {}
    private var onScheduleGoogleGrace: RightCmdGestureMonitor.Callback = {}
    private var onCancelGoogleGrace: RightCmdGestureMonitor.Callback = {}

    init(
        captureSnapshot: @escaping () -> FocusSnapshot?,
        activationKey: HotkeyModifierKey = HotkeyConfiguration.defaults.agentTextKey
    ) {
        self.captureSnapshot = captureSnapshot
        self.configuration = HotkeyConfiguration(
            agentTextKey: activationKey,
            agentVoiceKey: activationKey,
            agentVoiceGesture: .hold,
            // Placeholder Drop slot the Right-Cmd monitor never reads — see the
            // companion note in `setActivationKey`. `.holdSpace` is the real
            // Drop default; this initializer just needs a non-nil combo.
            dropVoiceTapCombo: .optionSlash
        )
    }

    init(
        captureSnapshot: @escaping () -> FocusSnapshot?,
        configuration: HotkeyConfiguration
    ) {
        self.captureSnapshot = captureSnapshot
        self.configuration = configuration
    }

    func configure(
        onSnapshot: @escaping RightCmdGestureMonitor.SnapshotCallback,
        onTap: @escaping RightCmdGestureMonitor.Callback,
        onVoiceTap: @escaping RightCmdGestureMonitor.Callback = {},
        onHoldStart: @escaping RightCmdGestureMonitor.Callback,
        onHoldEnd: @escaping RightCmdGestureMonitor.Callback,
        onCancel: @escaping RightCmdGestureMonitor.Callback,
        onScheduleThreshold: @escaping RightCmdGestureMonitor.Callback,
        onCancelThreshold: @escaping RightCmdGestureMonitor.Callback,
        onHotkeyKeyHeldChanged: @escaping (HotkeyModifierKey, Bool) -> Void = { _, _ in },
        onGoogleTextTap: @escaping RightCmdGestureMonitor.Callback = {},
        onGoogleVoiceTap: @escaping RightCmdGestureMonitor.Callback = {},
        onGoogleHoldStart: @escaping RightCmdGestureMonitor.Callback = {},
        onGoogleHoldEnd: @escaping RightCmdGestureMonitor.Callback = {},
        onGoogleCancel: @escaping RightCmdGestureMonitor.Callback = {},
        onScheduleGoogleGrace: @escaping RightCmdGestureMonitor.Callback = {},
        onCancelGoogleGrace: @escaping RightCmdGestureMonitor.Callback = {}
    ) {
        self.onSnapshot = onSnapshot
        self.onTap = onTap
        self.onVoiceTap = onVoiceTap
        self.onHoldStart = onHoldStart
        self.onHoldEnd = onHoldEnd
        self.onCancel = onCancel
        self.onScheduleThreshold = onScheduleThreshold
        self.onCancelThreshold = onCancelThreshold
        self.onHotkeyKeyHeldChanged = onHotkeyKeyHeldChanged
        self.onGoogleTextTap = onGoogleTextTap
        self.onGoogleVoiceTap = onGoogleVoiceTap
        self.onGoogleHoldStart = onGoogleHoldStart
        self.onGoogleHoldEnd = onGoogleHoldEnd
        self.onGoogleCancel = onGoogleCancel
        self.onScheduleGoogleGrace = onScheduleGoogleGrace
        self.onCancelGoogleGrace = onCancelGoogleGrace
    }

    func reset() {
        onCancelThreshold()
        onCancelGoogleGrace()
        clearHeldKey()
        activeKey = nil
        pendingAction = .agent
        pendingTapAction = nil
        pendingHoldEnabled = false
        state = .idle
    }

    func handle(_ input: Input) -> EventDisposition {
        switch (state, input) {
        case (.idle, .flagsChanged(let rawFlags)):
            guard let candidate = startCandidate(rawFlags: rawFlags) else {
                break
            }
            activeKey = candidate.key
            pendingAction = candidate.action
            pendingTapAction = candidate.tapAction
            pendingHoldEnabled = candidate.holdEnabled
            onSnapshot(captureSnapshot())
            state = .pending
            onHotkeyKeyHeldChanged(candidate.key, true)
            if candidate.holdEnabled {
                onScheduleThreshold()
            }

        case (.pending, .flagsChanged(let rawFlags))
            where activeKeyIsHeld(rawFlags) && !activeKeyIsOnly(rawFlags):
            cancelGesture()

        case (.holding, .flagsChanged(let rawFlags))
            where activeKeyIsHeld(rawFlags) && !activeKeyIsOnly(rawFlags):
            cancelGesture()

        case (.pending, .flagsChanged(let rawFlags)) where !activeKeyIsHeld(rawFlags):
            onCancelThreshold()
            let action = pendingTapAction
            state = .idle
            clearHeldKey()
            activeKey = nil
            pendingTapAction = nil
            pendingHoldEnabled = false
            switch action {
            case .text:
                fireTextTap()
            case .voice:
                fireVoiceTap()
            case nil:
                break
            }

        case (.holding, .flagsChanged(let rawFlags)) where !activeKeyIsHeld(rawFlags):
            onCancelThreshold()
            state = .idle
            clearHeldKey()
            activeKey = nil
            pendingTapAction = nil
            pendingHoldEnabled = false
            fireHoldEnd()

        case (.cancelledWaitingForRelease, .flagsChanged(let rawFlags)) where !activeKeyIsHeld(rawFlags):
            onCancelThreshold()
            state = .idle
            clearHeldKey()
            activeKey = nil
            pendingTapAction = nil
            pendingHoldEnabled = false

        case (.pending, .thresholdElapsed) where pendingHoldEnabled:
            if pendingAction == .google {
                // Variant A (founder-approved 2026-07-06): do NOT start Google
                // voice the instant the threshold elapses — park in a short
                // grace window first. The default ⌥M meeting toggle rides the
                // SAME right Option, so an M landing here used to flash the
                // Google recording UI before its cancel. A keypress in the
                // window now vetoes the start SILENTLY (nothing started — no
                // cancel callback either). Cost: a legit Google hold starts
                // `googleGraceMs` later. Agent holds (R⌘) are untouched.
                state = .googleGraceWaiting
                onScheduleGoogleGrace()
            } else {
                state = .holding
                fireHoldStart()
            }

        case (.googleGraceWaiting, .googleGraceElapsed):
            state = .holding
            fireHoldStart()

        case (.googleGraceWaiting, .keyDown), (.googleGraceWaiting, .mouseDown):
            // Silent veto: no google callbacks at all (a cancel would itself
            // blip UI); wait for release like any cancelled gesture.
            onCancelGoogleGrace()
            state = .cancelledWaitingForRelease

        case (.googleGraceWaiting, .flagsChanged(let rawFlags))
            where activeKeyIsHeld(rawFlags) && !activeKeyIsOnly(rawFlags):
            onCancelGoogleGrace()
            state = .cancelledWaitingForRelease

        case (.googleGraceWaiting, .flagsChanged(let rawFlags)) where !activeKeyIsHeld(rawFlags):
            // Released inside the grace window: the sub-grace hold never
            // started, so end silently — no start/end/cancel fired.
            onCancelGoogleGrace()
            onCancelThreshold()
            state = .idle
            clearHeldKey()
            activeKey = nil
            pendingTapAction = nil
            pendingHoldEnabled = false

        case (.pending, .keyDown), (.holding, .keyDown):
            cancelGesture()

        case (.pending, .mouseDown), (.holding, .mouseDown):
            cancelGesture()

        default:
            break
        }

        return .passThrough
    }

    private func cancelGesture() {
        onCancelThreshold()
        guard state == .pending || state == .holding else {
            return
        }
        state = .cancelledWaitingForRelease
        fireCancel()
    }

    private enum TapAction {
        case text
        case voice
    }

    private struct StartCandidate {
        let key: HotkeyModifierKey
        let action: GestureAction
        let tapAction: TapAction?
        let holdEnabled: Bool
    }

    private func startCandidate(rawFlags: UInt64) -> StartCandidate? {
        let key: HotkeyModifierKey
        if HotkeyFlags.isOnly(.rightCommand, rawFlags) {
            key = .rightCommand
        } else if HotkeyFlags.isOnly(.rightOption, rawFlags) {
            key = .rightOption
        } else {
            return nil
        }
        if let agent = candidate(
            key: key, action: .agent,
            textShortcut: configuration.agentTextShortcut,
            voiceShortcut: configuration.agentVoiceShortcut,
            voiceGesture: configuration.agentVoiceGesture
        ) { return agent }
        return candidate(
            key: key, action: .google,
            textShortcut: configuration.googleSearchTextShortcut,
            voiceShortcut: configuration.googleSearchVoiceShortcut,
            voiceGesture: configuration.googleSearchVoiceGesture
        )
    }

    private func candidate(
        key: HotkeyModifierKey,
        action: GestureAction,
        textShortcut: HotkeyShortcut,
        voiceShortcut: HotkeyShortcut,
        voiceGesture: HotkeyGesture
    ) -> StartCandidate? {
        let tapAction: TapAction?
        if textShortcut.modifierKey == key {
            tapAction = .text
        } else if voiceGesture == .tap, voiceShortcut.modifierKey == key {
            tapAction = .voice
        } else {
            tapAction = nil
        }
        let holdEnabled = voiceGesture == .hold && voiceShortcut.modifierKey == key
        guard tapAction != nil || holdEnabled else { return nil }
        return StartCandidate(key: key, action: action, tapAction: tapAction, holdEnabled: holdEnabled)
    }

    private func fireTextTap() { pendingAction == .google ? onGoogleTextTap() : onTap() }
    private func fireVoiceTap() { pendingAction == .google ? onGoogleVoiceTap() : onVoiceTap() }
    private func fireHoldStart() { pendingAction == .google ? onGoogleHoldStart() : onHoldStart() }
    private func fireHoldEnd() { pendingAction == .google ? onGoogleHoldEnd() : onHoldEnd() }
    private func fireCancel() { pendingAction == .google ? onGoogleCancel() : onCancel() }

    private func activeKeyIsHeld(_ rawFlags: UInt64) -> Bool {
        guard let activeKey else { return false }
        return HotkeyFlags.isHeld(activeKey, rawFlags)
    }

    private func activeKeyIsOnly(_ rawFlags: UInt64) -> Bool {
        guard let activeKey else { return false }
        return HotkeyFlags.isOnly(activeKey, rawFlags)
    }

    private func clearHeldKey() {
        if let activeKey {
            onHotkeyKeyHeldChanged(activeKey, false)
        } else {
            let keys = [
                configuration.agentTextShortcut.modifierKey,
                configuration.agentVoiceShortcut.modifierKey,
                configuration.googleSearchTextShortcut.modifierKey,
                configuration.googleSearchVoiceShortcut.modifierKey
            ].compactMap { $0 }
            Set(keys).forEach {
                onHotkeyKeyHeldChanged($0, false)
            }
        }
    }
}
