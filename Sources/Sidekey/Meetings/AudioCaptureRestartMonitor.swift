import Foundation

/// Debounces audio-device/configuration change notifications and runs a
/// restart closure only while the owning capture source is active.
final class AudioCaptureRestartMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let debounceNanoseconds: UInt64
    private let restart: @Sendable () async -> Void

    private var isActive = false
    private var generation: UInt64 = 0
    private var pendingTask: Task<Void, Never>?

    init(
        debounceNanoseconds: UInt64 = 250_000_000,
        restart: @escaping @Sendable () async -> Void
    ) {
        self.debounceNanoseconds = debounceNanoseconds
        self.restart = restart
    }

    deinit {
        pendingTask?.cancel()
    }

    func setActive(_ active: Bool) {
        let taskToCancel: Task<Void, Never>?
        lock.lock()
        isActive = active
        if active {
            taskToCancel = nil
        } else {
            generation &+= 1
            taskToCancel = pendingTask
            pendingTask = nil
        }
        lock.unlock()
        taskToCancel?.cancel()
    }

    func trigger() {
        let taskToCancel: Task<Void, Never>?
        let token: UInt64
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        generation &+= 1
        token = generation
        taskToCancel = pendingTask
        pendingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceNanoseconds)
            if Task.isCancelled { return }
            guard self.takeRestartIfCurrent(token: token) else { return }
            await self.restart()
        }
        lock.unlock()
        taskToCancel?.cancel()
    }

    private func takeRestartIfCurrent(token: UInt64) -> Bool {
        lock.lock()
        guard isActive, generation == token else {
            lock.unlock()
            return false
        }
        pendingTask = nil
        lock.unlock()
        return true
    }
}
