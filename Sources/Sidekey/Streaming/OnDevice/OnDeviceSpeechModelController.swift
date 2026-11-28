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
        if case .downloading = status {} else { status = .downloading(0) }
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
        status = .downloading(fraction)
    }
}
