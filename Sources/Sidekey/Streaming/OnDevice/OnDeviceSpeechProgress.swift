import Foundation

/// How long the model's download or preparation still needs, as the user
/// sees it. Settings, onboarding and the island read the same value.
// WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
enum OnDeviceSpeechTimeLeft: Equatable, Sendable {
    /// Too little data for an honest number yet.
    case estimating
    case seconds(TimeInterval)
    /// The download made no progress for a while.
    case stalled
    /// The preparation passed its expected duration.
    case longerThanUsual
}

/// The short copy for `OnDeviceSpeechTimeLeft`. Never counts below "less
/// than a minute" and never shows a percentage for the preparation.
enum OnDeviceSpeechProgressText {
    static func timeLeft(_ value: OnDeviceSpeechTimeLeft) -> String {
        switch value {
        case .estimating: return "Estimating time left…"
        case .seconds(let seconds):
            return seconds > 60 ? "About \(minutes(seconds)) min left" : "Less than a minute left"
        case .stalled: return "Stalled. Check your connection."
        case .longerThanUsual: return "Taking longer than usual, still working"
        }
    }

    /// The same for VoiceOver, without abbreviations.
    static func accessibilityTimeLeft(_ value: OnDeviceSpeechTimeLeft) -> String {
        switch value {
        case .estimating: return "estimating time left"
        case .seconds(let seconds):
            let count = minutes(seconds)
            return seconds > 60 ? "about \(count) minutes left" : "less than a minute left"
        case .stalled: return "stalled, check your connection"
        case .longerThanUsual: return "taking longer than usual, still working"
        }
    }

    /// Onboarding: the person need not wait on the page.
    static let continueHint = "You can continue; Drop works as soon as it's ready."

    static func minutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded(.up)) }
}

/// Time left for a download from its fraction over time. The rate is the
/// progress across the last `window` seconds, so a burst or a pause between
/// files does not swing the number; the shown value is smoothed.
struct OnDeviceDownloadRateEstimator: Equatable, Sendable {
    /// Seconds of data before a number appears.
    var minimumSampleTime: TimeInterval = 4
    /// Seconds without progress that count as stalled.
    var stallAfter: TimeInterval = 10
    var window: TimeInterval = 15
    var smoothing: Double = 0.35

    private var started: TimeInterval?
    private var samples: [Sample] = []
    private var lastProgressAt: TimeInterval?
    private var smoothed: TimeInterval?

    private struct Sample: Equatable, Sendable {
        let time: TimeInterval
        let fraction: Double
    }

    init() {}

    mutating func record(fraction: Double, at now: TimeInterval) {
        let fraction = min(1, max(0, fraction))
        if started == nil {
            started = now
            lastProgressAt = now
            samples = [Sample(time: now, fraction: fraction)]
            return
        }
        guard let last = samples.last, fraction > last.fraction else { return }
        samples.append(Sample(time: now, fraction: fraction))
        lastProgressAt = now
        while samples.count > 2, let first = samples.first, now - first.time > window { samples.removeFirst() }
        if let raw = rawSecondsLeft(at: now) {
            smoothed = smoothed.map { $0 + smoothing * (raw - $0) } ?? raw
        }
    }

    func timeLeft(at now: TimeInterval) -> OnDeviceSpeechTimeLeft {
        guard let started, let lastProgressAt, let last = samples.last else { return .estimating }
        if last.fraction >= 1 { return .seconds(0) }
        if now - lastProgressAt >= stallAfter { return .stalled }
        guard now - started >= minimumSampleTime, let smoothed else { return .estimating }
        // Time since the last sample counts down between callbacks.
        return .seconds(max(1, smoothed - (now - last.time)))
    }

    private func rawSecondsLeft(at now: TimeInterval) -> TimeInterval? {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return nil }
        let rate = (last.fraction - first.fraction) / (last.time - first.time)
        guard rate > 0 else { return nil }
        return (1 - last.fraction) / rate
    }
}

/// A preparation's kind: the first load after a download compiles the model
/// for the Neural Engine; later ones reuse the system's compiled copy.
enum OnDeviceSpeechPreparationKind: String, Sendable {
    case firstCompile
    case reload
}

/// The Mac's class for the expected preparation time.
struct OnDeviceSpeechMachine: Equatable, Sendable {
    /// The chip generation (1 for M1) or nil when unknown.
    let generation: Int?
    /// Pro, Max or Ultra.
    let isHighEnd: Bool
    let memoryGB: Int

    static let current: OnDeviceSpeechMachine = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return OnDeviceSpeechMachine(
            brand: String(cString: buffer),
            memoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }()

    init(generation: Int?, isHighEnd: Bool, memoryGB: Int) {
        self.generation = generation
        self.isHighEnd = isHighEnd
        self.memoryGB = memoryGB
    }

    /// From a brand string such as "Apple M2 Pro".
    init(brand: String, memoryBytes: UInt64) {
        let words = brand.split(separator: " ")
        let chip = words.first { $0.hasPrefix("M") && Int($0.dropFirst()) != nil }
        generation = chip.flatMap { Int($0.dropFirst()) }
        isHighEnd = words.contains { ["Pro", "Max", "Ultra"].contains(String($0)) }
        memoryGB = Int((Double(memoryBytes) / 1_073_741_824).rounded())
    }
}

/// Stored durations of earlier preparations on this Mac, and whether the
/// current download has been compiled yet.
protocol OnDeviceSpeechPreparationHistory: Sendable {
    var hasCompiled: Bool { get }
    func setCompiled(_ value: Bool)
    func lastDuration(_ kind: OnDeviceSpeechPreparationKind) -> TimeInterval?
    func record(_ kind: OnDeviceSpeechPreparationKind, seconds: TimeInterval)
}

final class UserDefaultsPreparationHistory: OnDeviceSpeechPreparationHistory, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let compiledKey = "sidekey.onDeviceSpeech.compiled.v1"
    private static func durationKey(_ kind: OnDeviceSpeechPreparationKind) -> String {
        "sidekey.onDeviceSpeech.preparationSeconds.\(kind.rawValue).v1"
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var hasCompiled: Bool { defaults.bool(forKey: Self.compiledKey) }
    func setCompiled(_ value: Bool) { defaults.set(value, forKey: Self.compiledKey) }

    func lastDuration(_ kind: OnDeviceSpeechPreparationKind) -> TimeInterval? {
        let value = defaults.double(forKey: Self.durationKey(kind))
        return value > 0 ? value : nil
    }

    func record(_ kind: OnDeviceSpeechPreparationKind, seconds: TimeInterval) {
        defaults.set(seconds, forKey: Self.durationKey(kind))
    }
}

/// The preparation has no progress signal, so its time left is the expected
/// duration minus the time it has run. Past the expectation it says so
/// instead of a wrong number.
struct OnDeviceSpeechPreparationEstimator: Sendable {
    let machine: OnDeviceSpeechMachine
    let history: any OnDeviceSpeechPreparationHistory

    /// Seconds a preparation is expected to take. A duration measured on this
    /// Mac wins, with headroom; otherwise the machine's class. The table is a
    /// proposal from one M4 Pro measurement and Neural Engine reports; it
    /// needs a real clean M1 measurement.
    func expectedSeconds(_ kind: OnDeviceSpeechPreparationKind) -> TimeInterval {
        if let last = history.lastDuration(kind) { return max(5, last * 1.25) }
        return Self.tableSeconds(kind, machine: machine)
    }

    static func tableSeconds(_ kind: OnDeviceSpeechPreparationKind, machine: OnDeviceSpeechMachine) -> TimeInterval {
        let small = machine.memoryGB <= 8
        switch kind {
        case .reload:
            return small ? 15 : 8
        case .firstCompile:
            let base: TimeInterval
            switch machine.generation {
            case 1: base = small ? 240 : 150
            case 2: base = small ? 180 : 120
            case 3: base = small ? 120 : 90
            case .some(let generation) where generation >= 4: base = small ? 90 : 60
            default: base = 180
            }
            return machine.isHighEnd ? base * 0.75 : base
        }
    }

    func timeLeft(elapsed: TimeInterval, kind: OnDeviceSpeechPreparationKind) -> OnDeviceSpeechTimeLeft {
        let remaining = expectedSeconds(kind) - elapsed
        return remaining > 0 ? .seconds(remaining) : .longerThanUsual
    }
}
