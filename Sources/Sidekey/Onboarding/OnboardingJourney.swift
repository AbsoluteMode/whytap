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

    /// The four acts of the progress bar: wider gaps separate them.
    var act: OnboardingAct {
        switch self {
        case .source, .speechKey, .llmKey, .search, .language: return .engine
        case .keyboard, .microphone, .inputMonitoring, .screenRecording: return .access
        case .tryDrop: return .tryDrop
        case .hotkeys, .toolbox, .help, .thanks: return .island
        }
    }

    /// The step's name in the footer ("Next: Language") and for VoiceOver.
    var shortTitle: String {
        switch self {
        case .source: return "Speech"
        case .speechKey: return "Speech key"
        case .llmKey: return "Language model"
        case .search: return "Web search"
        case .language: return "Language"
        case .keyboard: return "Keyboard"
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Keyboard access"
        case .screenRecording: return "Screen"
        case .tryDrop: return "Try Drop"
        case .hotkeys: return "Shortcuts"
        case .toolbox: return "Toolbox"
        case .help: return "whytap.ai"
        case .thanks: return "Finish"
        }
    }

    /// How long a success stays on screen before the next step (the dwell),
    /// or `nil` for the last step. Tour chapters move on after a reading pause.
    var dwell: TimeInterval? {
        switch self {
        case .source, .language: return 0.62
        // The padlock plays to the end first: the key turns, the shackle opens
        // and settles (the design pass moves on after 1.15 s).
        case .speechKey: return 1.15
        case .llmKey, .search, .keyboard, .microphone, .inputMonitoring, .screenRecording: return 0.78
        case .tryDrop: return 1.35
        case .hotkeys, .toolbox, .help: return 4.2
        case .thanks: return nil
        }
    }

    /// A step without an action of its own: it moves on after a reading pause
    /// (or Next), not after a success.
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

enum OnboardingAct: String, CaseIterable {
    case engine = "ENGINE"
    case access = "ACCESS"
    case tryDrop = "TRY DROP"
    case island = "ISLAND"
}

/// One segment of the progress bar. A step left out because it was already
/// done counts as completed; one a choice made unnecessary, or one skipped, is
/// a hollow "bypassed" segment, never a false "done".
enum OnboardingSegmentState: Equatable {
    case upcoming
    case current
    case completed
    case bypassed
}

struct OnboardingSegment: Equatable, Identifiable {
    let step: OnboardingStep
    let state: OnboardingSegmentState
    var id: OnboardingStep { step }
}

extension OnboardingJourney {
    /// Every step as a segment, in order; Input Monitoring only when it is on
    /// the way. `done` lists the steps whose action succeeded in this window.
    static func segments(start: OnboardingStart, progress: OnboardingProgress, current: OnboardingStep,
                         done: Set<OnboardingStep>) -> [OnboardingSegment] {
        let order = OnboardingStep.allCases
        let currentIndex = order.firstIndex(of: current) ?? 0
        return order.enumerated().compactMap { index, step in
            let onTheWay = isOnTheWay(step, start: start, progress: progress)
            if step == .inputMonitoring, !onTheWay { return nil }
            let state: OnboardingSegmentState
            if step == current {
                state = .current
            } else if done.contains(step) || (!onTheWay && doneAtStart(step, start)) {
                state = .completed
            } else if !onTheWay {
                state = .bypassed
            } else if index < currentIndex {
                state = step.isInformational ? .completed : .bypassed
            } else {
                state = .upcoming
            }
            return OnboardingSegment(step: step, state: state)
        }
    }

    private static func doneAtStart(_ step: OnboardingStep, _ start: OnboardingStart) -> Bool {
        switch step {
        case .source, .speechKey: return start.speechReady
        case .llmKey: return start.llmReady
        case .search: return start.searchReady
        case .language: return start.languageChosen
        case .keyboard: return start.keyboardGranted
        case .microphone: return start.microphoneGranted
        case .screenRecording: return start.screenRecordingGranted
        case .inputMonitoring, .tryDrop, .hotkeys, .toolbox, .help, .thanks: return false
        }
    }
}

/// Which way a step change went: the next step slides in from the right,
/// Back from the left.
enum OnboardingNavDirection: Int, Equatable {
    case forward = 1
    case backward = -1
}
