import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
@testable import Sidekey

/// The standalone preview's Drop on Try Drop. The preview starts no hotkeys
/// or event taps, so this listens for the person's own Drop shortcut inside
/// the preview's window (a local event monitor, whatever has the focus).
///
/// A held shortcut (Space, or a hold combo) runs through the app's own
/// SpaceHoldDetector with SpaceHoldMonitor's event mapping and swallow rule,
/// so the keys behave as with Drop in the app: a short Space tap types a
/// space; a hold past the threshold erases the spaces it printed, records,
/// swallows its auto-repeats and its release, and ends on release. A tap
/// shortcut starts with one press and ends with the next. A take always
/// ends: on release, when the window or the app loses focus, after
/// `longestTake`, and when Try Drop goes away (Continue, Skip, Back). A take
/// shorter than `shortestTake` brings nothing, like a real empty take.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
final class OnboardingPreviewDrop: OnboardingDropStandIn {
    static let text = "Moving our sync to Thursday at 3. I’ll send the new invite tonight."

    var shortestTake: TimeInterval = 0.6
    var longestTake: TimeInterval = 30
    /// How long the pretend transcription takes.
    var transcribing: TimeInterval = 0.45
    /// The hold threshold, Drop's own.
    var threshold: TimeInterval = Double(SpaceHoldDetector.holdThresholdMs) / 1000
    var now: () -> Date = Date.init
    /// Drop's "is the focused element an editable text field?" check.
    var isEditable: () -> Bool = {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return text.isEditable
    }
    /// Drop's Backspace for the trigger characters that printed before the
    /// hold was confirmed.
    var eraseLeaked: (Int) -> Void = { count in
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        for _ in 0..<count { text.deleteBackward(nil) }
    }

    private(set) var isListening = false
    private var shortcut: HotkeyShortcut = .holdSpace
    private var gesture: HotkeyGesture = .hold
    private var voice: OnboardingVoiceSignal?
    private var deliver: ((String) -> Void)?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var takeStarted: Date?
    private var keyDown = false
    private var generation = 0
    private var detector = SpaceHoldDetector()
    private var thresholdTask: Task<Void, Never>?

    var isRecording: Bool { takeStarted != nil }

    func attach(shortcut: HotkeyShortcut, gesture: HotkeyGesture, voice: OnboardingVoiceSignal,
                deliver: @escaping (String) -> Void) {
        detach()
        self.shortcut = shortcut
        self.gesture = shortcut == .holdSpace ? .hold : gesture
        self.voice = voice
        self.deliver = deliver
        isListening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interrupt() }
            })
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        isListening = false
        keyDown = false
        detector = SpaceHoldDetector()
        thresholdTask?.cancel()
        generation += 1
        // Leaving mid-take drops it: nothing arrives after the step is gone.
        if takeStarted != nil || voice?.working == true { voice?.phaseChanged(.idle) }
        takeStarted = nil
        voice = nil
        deliver = nil
    }

    /// One key event in the window: the Drop shortcut's events are handled,
    /// and the ones Drop swallows return `nil`; anything else passes through.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isListening else { return event }
        if gesture == .hold, let trigger = holdTrigger {
            return held(event, trigger: trigger)
        }
        switch shortcut {
        case .holdSpace:
            return event  // always a hold (above)
        case .combo(let combo):
            guard event.type != .flagsChanged, UInt32(event.keyCode) == combo.keyCode else { return event }
            if event.type == .keyDown {
                guard Self.carbon(event.modifierFlags) == combo.modifiers else { return event }
                pressed(isRepeat: event.isARepeat)
            } else {
                released()
            }
            return nil
        case .modifier(let key):
            let code = key == .rightCommand ? kVK_RightCommand : kVK_RightOption
            guard event.type == .flagsChanged, event.keyCode == UInt16(code) else { return event }
            let flag: NSEvent.ModifierFlags = key == .rightCommand ? .command : .option
            event.modifierFlags.contains(flag) ? pressed(isRepeat: false) : released()
            return event
        }
    }

    /// The key and modifiers of a held trigger, as Drop's Space monitor
    /// takes them (Space bare, or a hold combo).
    private var holdTrigger: (key: CGKeyCode, modifiers: CGEventFlags)? {
        switch shortcut {
        case .holdSpace: return (CGKeyCode(kVK_Space), [])
        case .combo(let combo): return (CGKeyCode(combo.keyCode), Self.cgFlags(carbon: combo.modifiers))
        case .modifier: return nil
        }
    }

    /// A held trigger: the app's detector decides, the app's rule swallows.
    private func held(_ event: NSEvent, trigger: (key: CGKeyCode, modifiers: CGEventFlags)) -> NSEvent? {
        let type: CGEventType
        switch event.type {
        case .keyDown: type = .keyDown
        case .keyUp: type = .keyUp
        default: return event
        }
        guard let mapped = SpaceHoldMonitor.mapEvent(
            type: type, keyCode: CGKeyCode(event.keyCode), isRepeat: event.isARepeat,
            flags: Self.cgFlags(event.modifierFlags), triggerKeyCode: trigger.key, requiredModifiers: trigger.modifiers
        ) else { return event }
        let before = detector.state
        let actions = detector.handle(mapped)
        perform(actions)
        let decision = SpaceHoldMonitor.tapDecision(for: mapped, beforeState: before, actions: actions,
                                                    triggerIsModifiedCombo: !trigger.modifiers.isEmpty)
        return decision == .swallow ? nil : event
    }

    private func feed(_ event: SpaceHoldDetector.Event) {
        perform(detector.handle(event))
    }

    private func perform(_ actions: [SpaceHoldDetector.Action]) {
        for action in actions {
            switch action {
            case .passThrough, .incrementLeak:
                break
            case .beginPending:
                thresholdTask?.cancel()
                let wait = threshold
                thresholdTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.feed(.thresholdFired)
                }
            case .requestEditableCheck:
                feed(.editableResolved(isEditable: isEditable()))
            case .cancelPending:
                thresholdTask?.cancel()
            case .arm(let deleteCount):
                eraseLeaked(deleteCount)
                start()
            case .stopAndTranscribe:
                end()
            case .cancelDrop:
                cancel()
            }
        }
    }

    /// A tap shortcut went down (a held key repeats: ignored).
    func pressed(isRepeat: Bool) {
        guard !isRepeat, !keyDown else { return }
        keyDown = true
        if takeStarted == nil { start() } else { end() }
    }

    /// A tap shortcut came up.
    func released() {
        keyDown = false
    }

    /// The window or the app lost focus: a held key's release would never
    /// arrive here, so the take ends now.
    func interrupt() {
        keyDown = false
        thresholdTask?.cancel()
        detector = SpaceHoldDetector()
        end()
    }

    private func start() {
        guard let voice, takeStarted == nil, !voice.working else { return }
        generation += 1
        let take = generation
        takeStarted = now()
        voice.phaseChanged(.recording)
        let longest = longestTake
        Task { @MainActor [weak self] in
            var t = 0.0
            let began = Date()
            while let self, self.generation == take, self.takeStarted != nil {
                if Date().timeIntervalSince(began) >= longest {
                    self.detector = SpaceHoldDetector()
                    self.end()
                    return
                }
                t += 0.05
                voice.setLevel(0.35 + 0.3 * abs(sin(t * 3.1)) + 0.15 * abs(sin(t * 7.3)))
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func end() {
        guard let voice, let started = takeStarted else { return }
        takeStarted = nil
        generation += 1
        let take = generation
        let heard = now().timeIntervalSince(started) >= shortestTake
        voice.phaseChanged(.transcribing)
        let wait = transcribing
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, self.generation == take else { return }
            guard heard else { voice.phaseChanged(.idle); return }
            voice.phaseChanged(.inserting)
            self.deliver?(Self.text)
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard self.generation == take else { return }
            voice.phaseChanged(.idle)
        }
    }

    /// Escape while recording: the take is dropped, as in Drop.
    private func cancel() {
        guard takeStarted != nil else { return }
        takeStarted = nil
        generation += 1
        voice?.phaseChanged(.idle)
    }

    private static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func cgFlags(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        return result
    }

    private static func cgFlags(carbon: UInt32) -> CGEventFlags {
        var result: CGEventFlags = []
        if carbon & UInt32(cmdKey) != 0 { result.insert(.maskCommand) }
        if carbon & UInt32(optionKey) != 0 { result.insert(.maskAlternate) }
        if carbon & UInt32(controlKey) != 0 { result.insert(.maskControl) }
        if carbon & UInt32(shiftKey) != 0 { result.insert(.maskShift) }
        return result
    }
}
