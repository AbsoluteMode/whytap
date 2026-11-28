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
    /// The download's last share: a number there would be noise.
    case almostDone
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
        case .almostDone: return "Almost done"
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
        case .almostDone: return "almost done"
        }
    }

    /// Onboarding: the person need not wait on the page.
    static let continueHint = "You can continue; Drop works as soon as it's ready."

    static func minutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded(.up)) }
}

/// Time left for a download from its byte fraction over time.
///
/// The rate comes only from a continuous run of reports (no gap over
/// `runGap`) inside the last `window` seconds, smoothed. A gap starts a new
/// run: between files the download makes a new request, and per-request
/// latency says nothing about the connection (recorded: 4.9% for four
/// seconds of small files, then 7% a second through the weight file). The
/// number shows while bytes flow steadily and is held for `hold` seconds
/// across a gap; otherwise there is no number. It never shows before
/// `minimumSampleTime` or the first percent, during a stall, past `nearEnd`
/// ("Almost done"), or above `maximumSeconds`. The first report is the
/// baseline: the downloader's first report already counts the files in
/// place, so they never read as speed.
struct OnDeviceDownloadRateEstimator: Equatable, Sendable {
    var minimumSampleTime: TimeInterval = 4
    /// Seconds without progress that count as stalled.
    var stallAfter: TimeInterval = 8
    var window: TimeInterval = 5
    var smoothing: Double = 0.5
    var nearEnd: Double = 0.98
    var maximumSeconds: TimeInterval = 2 * 3600
    var runGap: TimeInterval = 1
    /// A run needs this many reports within `steadySpan` to give a number.
    var steadyReports = 8
    var steadySpan: TimeInterval = 2
    var hold: TimeInterval = 5

    private var started: TimeInterval?
    private var samples: [Sample] = []
    private var runStart: Sample?
    private var lastProgressAt: TimeInterval?
    private var smoothedRate: Double?
    private var lastSteadyAt: TimeInterval?

    private struct Sample: Equatable, Sendable {
        let time: TimeInterval
        let fraction: Double
    }

    init() {}

    mutating func record(fraction: Double, at now: TimeInterval) {
        let fraction = min(1, max(0, fraction))
        let sample = Sample(time: now, fraction: fraction)
        if started == nil {
            started = now
            lastProgressAt = now
            samples = [sample]
            runStart = sample
            return
        }
        guard let last = samples.last, fraction > last.fraction else { return }
        if now - last.time > runGap { runStart = last }
        samples.append(sample)
        lastProgressAt = now
        samples.removeAll { now - $0.time > window }
        if samples.count >= steadyReports,
           samples.reversed().prefix(while: { now - $0.time <= steadySpan }).count >= steadyReports,
           let runStart {
            // The rate over this run, at most `window` back.
            let base = samples.first { $0.time >= runStart.time } ?? runStart
            if now - base.time >= 1 {
                let rate = (fraction - base.fraction) / (now - base.time)
                smoothedRate = smoothedRate.map { $0 + smoothing * (rate - $0) } ?? rate
                lastSteadyAt = now
            }
        }
    }

    func timeLeft(at now: TimeInterval) -> OnDeviceSpeechTimeLeft {
        guard let started, let lastProgressAt, let last = samples.last else { return .estimating }
        if last.fraction >= nearEnd { return .almostDone }
        if now - lastProgressAt >= stallAfter { return .stalled }
        guard now - started >= minimumSampleTime, last.fraction >= 0.01,
              let lastSteadyAt, now - lastSteadyAt <= hold,
              let smoothedRate, smoothedRate > 0 else { return .estimating }
        let seconds = (1 - last.fraction) / smoothedRate
        guard seconds <= maximumSeconds else { return .estimating }
        return .seconds(max(1, seconds))
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
