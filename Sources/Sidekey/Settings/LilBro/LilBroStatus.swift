import Foundation

/// What is wrong on this Mac, as Lil Bro tells whytap.ai with a question
/// (REV 17): a macOS permission missing or waiting for a restart, a provider
/// key the provider refused or that ran out of credit, a feature with no
/// working model, a provider's recent failure. Only what deviates from normal
/// is listed, so a Mac where everything works sends nothing (`isEmpty`).
///
/// Enumerated names and states only: never a key, a server address, a model
/// name, dictated text or an identifier of this Mac. The server drops anything
/// outside its own allowlist.
// WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md (REV 17)
struct LilBroStatus: Equatable {
    struct Failure: Equatable {
        /// `AIProviderKind` raw value (`openAICompatible` for any custom server).
        let provider: String
        /// `AIFeature` raw value.
        let feature: String
        /// `ProviderFailure` name.
        let kind: String
        let minutes: Int
    }

    var permissions: [String: String] = [:]
    var keys: [String: String] = [:]
    var routes: [String: String] = [:]
    var failures: [Failure] = []

    var isEmpty: Bool { permissions.isEmpty && keys.isEmpty && routes.isEmpty && failures.isEmpty }

    /// The JSON the server reads; empty when all is well.
    var json: [String: Any] {
        var out: [String: Any] = [:]
        if !permissions.isEmpty { out["permissions"] = permissions }
        if !keys.isEmpty { out["keys"] = keys }
        if !routes.isEmpty { out["routes"] = routes }
        if !failures.isEmpty {
            out["failures"] = failures.map {
                ["provider": $0.provider, "feature": $0.feature, "kind": $0.kind, "minutes": $0.minutes] as [String: Any]
            }
        }
        return out
    }

    /// From what the Features screens show, the key checks and the failure log.
    static func make(snapshot: FeatureSetupSnapshot, keyChecks: [AIProviderKind: KeyStatus],
                     failures: [LilBroFailureLog.Entry], now: Date) -> LilBroStatus {
        var status = LilBroStatus()
        if !snapshot.microphoneGranted { status.permissions["microphone"] = "missing" }
        if snapshot.keyboardNeedsRestart {
            status.permissions["accessibility"] = "needsRestart"
        } else if !snapshot.keyboardReady {
            status.permissions["accessibility"] = "missing"
        }
        if snapshot.screenNeedsRestart {
            status.permissions["screenRecording"] = "needsRestart"
        } else if !snapshot.screenRecordingGranted {
            status.permissions["screenRecording"] = "missing"
        }
        // macOS cannot be asked about System audio; only meetings need it.
        if snapshot.meetingsOn, !snapshot.systemAudioHeard { status.permissions["systemAudio"] = "unknown" }

        for (kind, check) in keyChecks {
            switch check {
            case .valid: break
            case .limited: status.keys[kind.rawValue] = "limited"
            case .unreachable: status.keys[kind.rawValue] = "unreachable"
            case .rejected(let why): status.keys[kind.rawValue] = why.rawValue
            }
        }

        for feature in AIFeature.activeCases where used(feature, snapshot) {
            if let state = routeState(snapshot.modelStatus(feature)) { status.routes[feature.rawValue] = state }
        }

        status.failures = failures
            .filter { now.timeIntervalSince($0.at) < LilBroFailureLog.lifetime }
            .sorted { $0.at > $1.at }
            .prefix(5)
            .map { Failure(provider: $0.provider.rawValue, feature: $0.feature.rawValue, kind: $0.failure.name,
                           minutes: max(0, Int(now.timeIntervalSince($0.at) / 60))) }
        return status
    }

    /// A feature the person uses: a feature that is off has no model on
    /// purpose, and that is not a problem to report.
    private static func used(_ feature: AIFeature, _ snapshot: FeatureSetupSnapshot) -> Bool {
        switch feature {
        case .dropFast: return snapshot.dropMode == .fast
        case .dropSmart, .dropSmartCleanup: return snapshot.dropMode == .smart
        case .meetings, .meetingNotes: return snapshot.meetingsOn
        case .agent, .agentVoice: return snapshot.agentOn
        default: return snapshot.modelStatus(feature) != .notSet
        }
    }

    private static func routeState(_ status: ModelRowStatus) -> String? {
        switch status {
        case .ok, .expiring: return nil
        case .notSet: return "notSet"
        case .keyProblem: return "keyProblem"
        case .notVerified: return nil
        case .removedByProvider: return "removedByProvider"
        case .deprecatedAlias: return "deprecated"
        case .notSupported: return "notSupported"
        }
    }
}

/// The last failure of each provider in each feature, kept in memory for a
/// day so Lil Bro can say why something stopped working. The kind and the
/// time only: never the provider's message (it can quote dictated text).
// WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md (REV 17)
@MainActor
final class LilBroFailureLog {
    static let shared = LilBroFailureLog()
    static let lifetime: TimeInterval = 24 * 60 * 60

    struct Entry: Equatable {
        let provider: AIProviderKind
        let feature: AIFeature
        let failure: ProviderFailure
        let at: Date
    }

    private(set) var entries: [Entry] = []

    func record(_ failure: ProviderFailure, provider: AIProviderKind, feature: AIFeature, at: Date = Date()) {
        entries.removeAll { ($0.provider == provider && $0.feature == feature) || at.timeIntervalSince($0.at) >= Self.lifetime }
        entries.append(Entry(provider: provider, feature: feature, failure: failure, at: at))
    }

    /// A working answer from the provider ends its failure there.
    func clear(provider: AIProviderKind, feature: AIFeature) {
        entries.removeAll { $0.provider == provider && $0.feature == feature }
    }
}

extension ProviderFailure {
    /// The name the server knows.
    var name: String {
        switch self {
        case .keyRefused: return "keyRefused"
        case .missingPermission: return "missingPermission"
        case .outOfCredit: return "outOfCredit"
        case .refused: return "refused"
        case .busy: return "busy"
        case .notResponding: return "notResponding"
        case .noConnection: return "noConnection"
        }
    }
}
