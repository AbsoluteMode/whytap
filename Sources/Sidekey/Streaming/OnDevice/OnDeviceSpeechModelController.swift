import Foundation

/// The on-device model's state for Settings. One shared instance owns the
/// download, so closing the form or the window does not stop it.
@MainActor
final class OnDeviceSpeechModelController: ObservableObject {
    static let shared = OnDeviceSpeechModelController()

    @Published private(set) var status: OnDeviceSpeechModelStatus = .notDownloaded {
        didSet { if status != oldValue { statusChanged() } }
    }
    /// Time left while downloading or preparing; nil otherwise. Settings and
    /// onboarding show the same value.
    // WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
    @Published private(set) var timeLeft: OnDeviceSpeechTimeLeft?

    private let store: any OnDeviceSpeechModelManaging
    private let now: @MainActor () -> TimeInterval
    private let tickInterval: Duration?
    private var rate = OnDeviceDownloadRateEstimator()
    private var ticker: Task<Void, Never>?

    /// `tickInterval` nil: no timer; tests call `tick()`.
    init(
        store: any OnDeviceSpeechModelManaging = OnDeviceSpeechModelStore.shared,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        tickInterval: Duration? = .seconds(1)
    ) {
        self.store = store
        self.now = now
        self.tickInterval = tickInterval
    }

    /// Recomputes `timeLeft` from the clock: a stalled download or a long
    /// preparation changes the copy without any new event.
    func tick() async {
        switch status {
        case .downloading:
            timeLeft = rate.timeLeft(at: now())
        case .preparing:
            timeLeft = await store.preparationTimeLeft() ?? .estimating
        case .notDownloaded, .ready, .failed, .loadFailed:
            timeLeft = nil
        }
    }

    private func statusChanged() {
        switch status {
        case .downloading:
            if timeLeft == nil { timeLeft = .estimating }
            startTicker()
        case .preparing:
            if timeLeft == nil || timeLeft == .stalled { timeLeft = .estimating }
            startTicker()
            Task { await tick() }
        case .notDownloaded, .ready, .failed, .loadFailed:
            timeLeft = nil
            ticker?.cancel()
            ticker = nil
        }
    }

    private func startTicker() {
        guard ticker == nil, let interval = tickInterval else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    /// Reads the state and, when the files are in place but the model is not
    /// loaded in this launch, prepares it, so the card never says Ready
    /// before a take would work.
    func refresh() async {
        status = await store.status()
        if status == .preparing { await prepare() }
    }

    /// Loads the model (joins a preparation in progress); `true` when it is
    /// loaded afterwards.
    @discardableResult
    func prepare() async -> Bool {
        if status == .loadFailed { status = .preparing }
        let loaded = await store.prepare()
        status = await store.status()
        return loaded
    }

    /// `true` when the model's files are in place afterwards; by then the
    /// model has also been prepared (Ready), or its load failed. A second
    /// call while a download runs joins it.
    // WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
    @discardableResult
    func download() async -> Bool {
        if case .downloading = status {} else {
            // The downloader's first report is the baseline (files already
            // on disk count there), not a zero recorded here.
            rate = OnDeviceDownloadRateEstimator()
            status = .downloading(0)
        }
        do {
            try await store.download { [weak self] fraction in
                Task { @MainActor in self?.advance(to: fraction) }
            }
        } catch {
            // The status says the rest: failed, or not downloaded after Cancel.
        }
        status = await store.status()
        if status == .preparing { await prepare() }
        return Self.filesInPlace(status)
    }

    static func filesInPlace(_ status: OnDeviceSpeechModelStatus) -> Bool {
        switch status {
        case .preparing, .ready, .loadFailed: return true
        case .notDownloaded, .downloading, .failed: return false
        }
    }

    /// Cancels a running download and removes the model's files.
    @discardableResult
    func remove() async -> Bool {
        do {
            try await store.delete()
        } catch {
            status = await store.status()
            return false
        }
        status = await store.status()
        return true
    }

    /// Progress callbacks arrive from any queue, so a late one never moves the
    /// bar back or reopens a finished download.
    private func advance(to fraction: Double) {
        guard case .downloading(let current) = status, fraction > current else { return }
        rate.record(fraction: fraction, at: now())
        status = .downloading(fraction)
        timeLeft = rate.timeLeft(at: now())
    }
}
