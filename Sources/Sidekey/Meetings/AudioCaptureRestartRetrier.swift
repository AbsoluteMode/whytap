import Foundation

/// Retries capture restarts while CoreAudio/AVAudioEngine settle after a
/// route change. Device switches can briefly expose stale formats; a later
/// attempt often succeeds once the HAL graph catches up.
struct AudioCaptureRestartRetrier {
    let delaysNanoseconds: [UInt64]
    private let sleep: (UInt64) async -> Void

    init(
        delaysNanoseconds: [UInt64],
        sleep: @escaping (UInt64) async -> Void = { delay in
            try? await Task.sleep(nanoseconds: delay)
        }
    ) {
        self.delaysNanoseconds = delaysNanoseconds
        self.sleep = sleep
    }

    func run(
        operation: (Int) async throws -> Void,
        onFailure: (Int, Error) async -> Void
    ) async throws {
        var lastError: Error?
        for (index, delay) in delaysNanoseconds.enumerated() {
            if delay > 0 {
                await sleep(delay)
                if Task.isCancelled { throw CancellationError() }
            }

            let attempt = index + 1
            do {
                try await operation(attempt)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                await onFailure(attempt, error)
            }
        }

        throw lastError ?? CancellationError()
    }
}
