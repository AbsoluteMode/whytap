import Foundation

/// The on-device model's state for Settings. One shared instance owns the
/// download, so closing the form or the window does not stop it.
@MainActor
final class OnDeviceSpeechModelController: ObservableObject {
    static let shared = OnDeviceSpeechModelController()

    @Published private(set) var status: OnDeviceSpeechModelStatus = .notDownloaded

    private let store: any OnDeviceSpeechModelManaging

    init(store: any OnDeviceSpeechModelManaging = OnDeviceSpeechModelStore.shared) {
        self.store = store
    }

    func refresh() async {
        status = await store.status()
    }

    /// `true` when the model is in place afterwards. A second call while a
    /// download runs joins it.
    @discardableResult
    func download() async -> Bool {
        if case .downloading = status {} else { status = .downloading(0) }
        do {
            try await store.download { [weak self] fraction in
                Task { @MainActor in self?.advance(to: fraction) }
            }
        } catch {
            // The status says the rest: failed, or not downloaded after Cancel.
        }
        status = await store.status()
        return status == .ready
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
        status = .downloading(fraction)
    }
}
