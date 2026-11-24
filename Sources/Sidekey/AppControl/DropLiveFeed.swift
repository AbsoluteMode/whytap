import Darwin
import Foundation
import WhytapCaseKit

/// Live state of the current Drop take for one allowed dictation client
/// (`drop_live`): phase, the cumulative partial text, the microphone level
/// and the orb's voice energy, so an app with its own input field can show
/// the words as they are spoken and drive its own orb.
///
/// - Who: only the clients in `allowedClients`, recognised like coding
///   harnesses (Apple-vouched Team ID plus signing identifier of the helper's
///   direct parent) and after the user's one-time Yes. This list gives nothing
///   else: meetings, Vocab/Filler writes and Case stay out of its reach.
/// - Text: only while a take is running and it is going into the calling
///   app's own process; any other take shows its phase and level, never words.
/// - Wing: a call with `showsLiveText: true` keeps an opt-in for
///   `optInDuration`. While it holds and the take goes into that client, the
///   island's recording wing gets no partials (the orb and phase stay). When
///   it lapses, the next partial reaches the wing as before.
/// - Nothing here is logged; the text lives only in memory, as the wing's does.
// WHY: .project-docs/decisions/2026-11-24-drop-live-for-dictation-clients.md
@MainActor
final class DropLiveFeed {
    static let operation = "drop_live"
    static let optInDuration: TimeInterval = 1.5

    /// Apps with their own text input that may read the live take, by
    /// Apple-vouched Team ID and signing identifier of their main executable.
    /// Separate from `CaseCallerResolver.knownAIApps`: being listed here opens
    /// `drop_live` only.
    static let allowedClients: [(name: String, teamID: String, identifier: String)] = [
        ("Whycode", "UVBKCN5PPV", "com.rootwise.whycode"),
    ]

    private let uptime: @MainActor () -> TimeInterval
    private let phase: @MainActor () -> String
    private let level: @MainActor () -> Float?
    private let energy: @MainActor (Float) -> Float

    private(set) var takeID = ""
    private var target: pid_t?
    private var text = ""
    private var optIn: (pid: pid_t, until: TimeInterval)?

    init(uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         phase: @escaping @MainActor () -> String = { String(describing: AppState.shared.phase) },
         level: @escaping @MainActor () -> Float? = { AppState.shared.audioLevels.last },
         energy: @escaping @MainActor (Float) -> Float = { raw in
             Float(VoiceOrbView.voiceEnergy(raw: CGFloat(raw), floor: NoiseFloorEstimator.shared.floor,
                                            normalize: NoiseFloorEstimator.shared.normalize))
         }) {
        self.uptime = uptime
        self.phase = phase
        self.level = level
        self.energy = energy
    }

    /// A new take toward the app that was frontmost at hotkey-down. A take
    /// into one of Whytap's own editors has no pid and goes to no client.
    func beginTake(target: pid_t?) {
        takeID = UUID().uuidString
        self.target = target
        text = ""
    }

    /// The provider's cumulative partial. A transient blank one keeps the
    /// last words, as the wing does.
    func partial(_ text: String) {
        guard text.contains(where: { !$0.isWhitespace }) else { return }
        self.text = text
    }

    /// True while an allowed client asked to show the text itself and the
    /// running take goes into that client.
    var suppressesWing: Bool {
        guard let optIn, uptime() < optIn.until, let target, phase() != "idle" else { return false }
        return target == optIn.pid
    }

    /// `clientPID` is the verified caller's own process (the helper's parent).
    func handle(_ args: [String: AppControlValue], clientPID: pid_t) -> AppControlResponse {
        guard Set(args.keys).isSubset(of: ["showsLiveText"]),
              args["showsLiveText"] == nil || args["showsLiveText"]?.bool != nil else {
            return .failure("invalid_arguments", "drop_live takes only showsLiveText (boolean).")
        }
        let current = phase()
        let toCaller = current != "idle" && target != nil && target == clientPID
        if args["showsLiveText"]?.bool == true {
            optIn = (clientPID, uptime() + Self.optInDuration)
        } else if optIn?.pid == clientPID {
            optIn = nil
        }
        let raw = max(0, min(1, level() ?? 0))
        let voice = current == "idle" ? 0 : max(0, min(1, energy(raw)))
        return .success(.object([
            "takeId": .string(takeID),
            "phase": .string(current),
            "toCaller": .bool(toCaller),
            "text": .string(toCaller ? text : ""),
            "level": .double(Self.rounded(raw)),
            "energy": .double(Self.rounded(voice)),
        ]))
    }

    /// Three decimals: enough for an orb, short on a 10 Hz poll.
    static func rounded(_ value: Float) -> Double { (Double(value) * 1000).rounded() / 1000 }
}
