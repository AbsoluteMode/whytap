import Foundation
import SwiftUI

/// Auto-cycling permissions surface for the preview. Runs through the
/// pending -> requesting -> granted progression for Mic, then
/// Accessibility, holds the "all-done" state for a beat, and loops. Lets
/// us iterate on the permissions screen visuals without granting / revoking
/// system permissions on every change.
@MainActor
final class MockPermissionsSurface: ObservableObject, OnboardingPermissionsSurface {
    @Published private(set) var mic: OnboardingPermissionStatus = .pending
    @Published private(set) var accessibility: OnboardingPermissionStatus = .pending

    private var task: Task<Void, Never>?

    var allRequiredGranted: Bool {
        mic == .granted && accessibility == .granted
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.runCycle()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Mock backend ignores explicit user clicks — the auto-cycle
    /// drives state. Buttons still update visually when the cycle
    /// reaches the requesting / granted beat for that permission.
    func requestMic() {}
    func requestAccessibility() {}

    private func runCycle() async {
        mic = .pending
        accessibility = .pending
        await sleep(1.6)
        guard !Task.isCancelled else { return }

        mic = .requesting
        await sleep(1.0)
        guard !Task.isCancelled else { return }
        mic = .granted
        await sleep(0.7)
        guard !Task.isCancelled else { return }

        accessibility = .requesting
        await sleep(1.2)
        guard !Task.isCancelled else { return }
        accessibility = .granted
        await sleep(3.0)
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
