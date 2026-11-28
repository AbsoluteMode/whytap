import Combine
import Foundation
import os.log

/// Prepares the on-device model at launch and whenever a feature is switched
/// to On this Mac, so the first take does not pay for the Core ML load (the
/// first one after a download compiles the model for the Neural Engine and can
/// take minutes on an older Mac). Loads only files already on this Mac: no
/// download and no network.
// WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
@MainActor
final class OnDeviceSpeechWarmup {
    static let shared = OnDeviceSpeechWarmup()

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "on-device-speech")

    private let routing: AIRoutingStore
    private let readiness: OnDeviceSpeechReadiness
    private let prepare: @Sendable () async -> Void
    private var subscription: AnyCancellable?
    private var usedThisMac = false
    /// The launch preparation (nil when no feature runs on this Mac or the
    /// model is not downloaded). Other launch work that compiles for the
    /// Neural Engine waits for it (`LaunchModelPreparation`); once finished,
    /// awaiting it returns at once.
    private(set) var launchPreparation: Task<Void, Never>?

    init(
        routing: AIRoutingStore? = nil,
        readiness: OnDeviceSpeechReadiness = .live,
        prepare: @escaping @Sendable () async -> Void = { await OnDeviceSpeechModelStore.shared.prepare() }
    ) {
        self.routing = routing ?? .shared
        self.readiness = readiness
        self.prepare = prepare
    }

    /// Whether any feature runs on this Mac.
    nonisolated static func usesThisMac(_ state: AIRoutingState) -> Bool {
        state.routes.values.contains { $0.account == .thisMac }
    }

    func start() {
        guard subscription == nil else { return }
        usedThisMac = Self.usesThisMac(routing.state)
        if usedThisMac { prepareIfReady(reason: "launch") }
        // `$state` publishes the new value before the store holds it, so the
        // value itself is read.
        subscription = routing.$state.dropFirst().sink { [weak self] state in
            guard let self else { return }
            let uses = Self.usesThisMac(state)
            defer { self.usedThisMac = uses }
            if uses, !self.usedThisMac { self.prepareIfReady(reason: "route") }
        }
    }

    private func prepareIfReady(reason: String) {
        guard readiness.isReady() else { return }
        os_log("on-device model: warm-up reason=%{public}@", log: Self.log, type: .info, reason)
        let prepare = self.prepare
        let task = Task(priority: .utility) { await prepare() }
        if reason == "launch" { launchPreparation = task }
    }
}
