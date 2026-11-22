import AppKit
import Carbon.HIToolbox
import Foundation
@testable import Sidekey

/// The standalone preview's Drop on Try Drop. The preview starts no hotkeys
/// or event taps, so this listens for the person's own Drop shortcut inside
/// the preview's window (a local event monitor, whatever has the focus) and
/// swallows it, so holding Space never types spaces into the field. Hold
/// starts a take and letting go ends it (a tap shortcut: press to start,
/// press again to end). A take always ends: on release, when the window or
/// the app loses focus, after `longestTake`, and when Try Drop goes away
/// (Continue, Skip, Back). A take shorter than `shortestTake` brings nothing,
/// like a real empty take.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
final class OnboardingPreviewDrop: OnboardingDropStandIn {
    static let text = "Moving our sync to Thursday at 3. I’ll send the new invite tonight."

    var shortestTake: TimeInterval = 0.6
    var longestTake: TimeInterval = 30
    /// How long the pretend transcription takes.
    var transcribing: TimeInterval = 0.45
    var now: () -> Date = Date.init

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

    var isRecording: Bool { takeStarted != nil }

    func attach(shortcut: HotkeyShortcut, gesture: HotkeyGesture, voice: OnboardingVoiceSignal,
                deliver: @escaping (String) -> Void) {
        detach()
        self.shortcut = shortcut
        self.gesture = gesture
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
        generation += 1
        // Leaving mid-take drops it: nothing arrives after the step is gone.
        if takeStarted != nil || voice?.working == true { voice?.phaseChanged(.idle) }
        takeStarted = nil
        voice = nil
        deliver = nil
    }

    /// One key event in the window: the Drop shortcut is handled and
    /// swallowed (`nil`), anything else passes through.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isListening else { return event }
        switch shortcut {
        case .holdSpace:
            guard event.type != .flagsChanged, event.keyCode == UInt16(kVK_Space),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            event.type == .keyDown ? pressed(isRepeat: event.isARepeat) : released()
            return nil
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

    /// The shortcut went down (a held key repeats: ignored).
    func pressed(isRepeat: Bool) {
        guard !isRepeat, !keyDown else { return }
        keyDown = true
        if gesture == .hold || takeStarted == nil { start() } else { end() }
    }

    /// The shortcut came up.
    func released() {
        guard keyDown else { return }
        keyDown = false
        if gesture == .hold { end() }
    }

    /// The window or the app lost focus: a held key's release would never
    /// arrive here, so the take ends now.
    func interrupt() {
        keyDown = false
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
                if Date().timeIntervalSince(began) >= longest { self.end(); return }
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

    private static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
