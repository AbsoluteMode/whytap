import Foundation

/// The steps of the first-launch onboarding, in their only order. One
/// decision or one action per step; a step whose action succeeds moves on by
/// itself, and only the informational steps have a Next button.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
enum OnboardingStep: String, CaseIterable, Equatable {
    /// On this Mac or your own key: two cards.
    case source
    /// Your key: the speech provider's key. Its pick sets the shared Speech row.
    case speechKey
    /// Your key: an optional language model key. Its pick sets the shared LLM row.
    case llmKey
    /// An optional web search for the Agent. Shown only with a language model.
    case search
    /// The language the user speaks.
    case language
    /// Accessibility ("Keyboard control"): the Drop shortcut, the Agent key and paste.
    case keyboard
    /// Microphone: Drop, Agent voice and Meetings.
    case microphone
    /// Input Monitoring: only when the Drop shortcut's event tap could not be
    /// created with Accessibility granted (the lazy fallback).
    case inputMonitoring
    /// Optional Screen Recording for Shot and the Agent's screen capture.
    case screenRecording
    /// Hold the Drop shortcut and dictate into a real field.
    case tryDrop
    /// What the shortcuts do.
    case hotkeys
    /// The tools hovering the island shows.
    case toolbox
    /// The agent on whytap.ai answers questions with detailed instructions.
    case help
    /// Thank you for choosing Whytap.
    case thanks

    /// A step the user can pass without doing it. Required steps still have
    /// "Set up later" in the window; this marks the ones that are a real choice.
    var isOptional: Bool {
        switch self {
        case .llmKey, .search, .screenRecording, .tryDrop: return true
        default: return false
        }
    }

    /// A step without an action of its own: it has Next instead of moving on
    /// by itself.
    var isInformational: Bool {
        switch self {
        case .hotkeys, .toolbox, .help, .thanks: return true
        default: return false
        }
    }
}

/// Where speech runs, chosen on the first step.
enum OnboardingSpeechSource: Equatable {
    case onThisMac
    case yourKey
}

/// What was already true when the window opened. A step done before the
/// onboarding is never shown, so a person who returns after a quit sees only
/// what is left.
struct OnboardingStart: Equatable {
    /// Every shared Speech feature already has a working route.
    var speechReady = false
    /// The shared LLM already has a working route.
    var llmReady = false
    /// A search for the Agent already works.
    var searchReady = false
    /// The input language is set (not Auto).
    var languageChosen = false
    var keyboardGranted = false
    var microphoneGranted = false
    var screenRecordingGranted = false
    /// This Mac can run speech locally (Apple Silicon).
    var onDeviceSupported = true

    static let cleanMac = OnboardingStart()
}

/// What the person did or what macOS reported during this onboarding. Only
/// the facts that change which steps are on the way.
struct OnboardingProgress: Equatable {
    var source: OnboardingSpeechSource?
    /// A language model route exists, before or during the onboarding.
    var hasLanguageModel = false
    /// The Drop shortcut reports that it needs Input Monitoring.
    var needsInputMonitoring = false
    /// Speech is on the way: a working route, or the local model downloading.
    var speechExpected = false
    /// A Drop press found Keyboard control or the microphone missing after
    /// their steps were left out: they come back.
    var permissionsMissing = false
}

enum OnboardingJourney {
    /// The steps on the way, in order. Steps done before the window opened
    /// are left out; steps the choices made unnecessary are left out too, so
    /// the progress bar counts only what this person will see.
    static func steps(start: OnboardingStart, progress: OnboardingProgress) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { isOnTheWay($0, start: start, progress: progress) }
    }

    static func isOnTheWay(_ step: OnboardingStep, start: OnboardingStart, progress: OnboardingProgress) -> Bool {
        switch step {
        case .source:
            // Without local speech there is nothing to choose: your key it is.
            return !start.speechReady && start.onDeviceSupported
        case .speechKey:
            guard !start.speechReady else { return false }
            return !start.onDeviceSupported || progress.source != .onThisMac
        case .llmKey:
            return !start.llmReady
        case .search:
            return !start.searchReady && (start.llmReady || progress.hasLanguageModel)
        case .language:
            return !start.languageChosen
        case .keyboard:
            return !start.keyboardGranted || progress.permissionsMissing
        case .microphone:
            return !start.microphoneGranted || progress.permissionsMissing
        case .inputMonitoring:
            return progress.needsInputMonitoring
        case .screenRecording:
            return !start.screenRecordingGranted
        case .tryDrop:
            return start.speechReady || progress.speechExpected
        case .hotkeys, .toolbox, .help, .thanks:
            return true
        }
    }

    static func next(after step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep? {
        guard let index = steps.firstIndex(of: step) else {
            // The step left the way (a choice removed it): continue from its place.
            return steps.first { order($0) > order(step) }
        }
        return steps.indices.contains(index + 1) ? steps[index + 1] : nil
    }

    static func previous(before step: OnboardingStep, in steps: [OnboardingStep]) -> OnboardingStep? {
        guard let index = steps.firstIndex(of: step) else {
            return steps.last { order($0) < order(step) }
        }
        return index > 0 ? steps[index - 1] : nil
    }

    /// The share of the way done when `step` is shown: the first step shows
    /// an empty bar, the last one a full bar.
    static func fraction(at step: OnboardingStep, in steps: [OnboardingStep]) -> Double {
        guard steps.count > 1, let index = steps.firstIndex(of: step) else { return steps.isEmpty ? 0 : 1 }
        return Double(index) / Double(steps.count - 1)
    }

    private static func order(_ step: OnboardingStep) -> Int {
        OnboardingStep.allCases.firstIndex(of: step) ?? 0
    }
}

/// The automatic move to the next step after a success. A step moves on
/// only on a success event while it is shown (a key accepted, a permission
/// turning granted, a dictation arriving), after a short beat that shows the
/// success. Arriving at a step that is already done is not an event, so Back
/// to a finished step stays there.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
struct OnboardingAutoAdvance: Equatable {
    /// How long the success is shown before the next step.
    static let beat: TimeInterval = 0.9

    private(set) var pending: OnboardingStep?

    /// Call when `step`'s action succeeds. Returns `true` when the move should
    /// be scheduled: only for the shown step, never twice.
    mutating func succeeded(_ step: OnboardingStep, current: OnboardingStep) -> Bool {
        guard step == current, !step.isInformational, pending == nil else { return false }
        pending = step
        return true
    }

    /// Call when the beat ends. Returns `true` when the move still applies:
    /// Back or another step shown in between cancels it.
    mutating func fire(current: OnboardingStep) -> Bool {
        defer { pending = nil }
        return pending == current && pending != nil
    }

    /// Call whenever a step is shown by navigation.
    mutating func cancel() { pending = nil }
}
