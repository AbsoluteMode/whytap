import Darwin
import Foundation
import WhytapCaseKit

/// Live state of the current Drop take for one allowed dictation client
/// (`drop_live`): phase, the partial text so far, the microphone level and
/// the orb's voice energy, so an app with its own input field can show the
/// words as they are spoken and drive its own orb.
///
/// - Who: only the clients in `allowedClients`, recognised like coding
///   harnesses (Apple-vouched Team ID plus signing identifier of the helper's
///   direct parent) and after the user's one-time Yes. This list gives nothing
///   else: meetings, Vocab/Filler writes and Case stay out of its reach.
/// - Text: only while a take is in a phase that can still deliver
///   (`deliveringPhases`) and it is going into the calling app's own process;
///   any other take shows its phase and level, never words. Partials are
///   bound to the take that produced them (`partial(_:take:)`), and
///   `endTake()` drops the words and the target when the take ends, fails or
///   is parked for a retry.
/// - Long on-device takes: that session re-decodes only its trailing ~14 s,
///   so its partial is a moving window. For such a take (`markWindowed`) the
///   feed keeps the words already shown and joins each window onto them where
///   the two overlap (`stitch`), so the client's field does not lose its
///   start. It is a preview: Drop's paste of the final text replaces it.
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
    /// Phases in which the running take can still put text into the field.
    static let deliveringPhases: Set<String> = ["recording", "transcribing", "verifying", "inserting", "finishing"]

    /// Apps with their own text input that may read the live take, by
    /// Apple-vouched Team ID and signing identifier of their main executable.
    /// Separate from `CaseCallerResolver.knownAIApps`: being listed here opens
    /// `drop_live` only.
    static let allowedClients: [(name: String, teamID: String, identifier: String)] = [
        ("Whycode", "UVBKCN5PPV", "com.rootwise.whycode"),
    ]

    /// The listed app's name, for Settings; nil for anyone else.
    static func allowedName(for identity: HarnessIdentity) -> String? {
        allowedClients.first { $0.teamID == identity.teamID && $0.identifier == identity.signingIdentifier }?.name
    }

    private let uptime: @MainActor () -> TimeInterval
    private let phase: @MainActor () -> String
    private let level: @MainActor () -> Float?
    private let energy: @MainActor (Float) -> Float

    private(set) var takeID = ""
    private var target: pid_t?
    private var text = ""
    private var windowed = false
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
    /// Returns the take's id, which its partials must carry.
    @discardableResult
    func beginTake(target: pid_t?) -> String {
        takeID = UUID().uuidString
        self.target = target
        text = ""
        windowed = false
        return takeID
    }

    /// The take's speech source sends a moving window rather than the whole
    /// take so far (on-device transcription).
    func markWindowed(take: String) {
        guard take == takeID, target != nil else { return }
        windowed = true
    }

    /// The take ended (pasted, failed, cancelled, parked for retry): its
    /// words and destination are gone, and late partials are ignored.
    func endTake() {
        target = nil
        text = ""
        windowed = false
    }

    /// The provider's partial for `take`. One from another (older) take, or
    /// after the take ended, is dropped. A transient blank one keeps the last
    /// words, as the wing does.
    func partial(_ text: String, take: String) {
        guard take == takeID, target != nil, text.contains(where: { !$0.isWhitespace }) else { return }
        self.text = windowed ? Self.stitch(shown: self.text, window: text) : text
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
        let toCaller = Self.deliveringPhases.contains(current) && target != nil && target == clientPID
        if args["showsLiveText"]?.bool == true {
            optIn = (clientPID, uptime() + Self.optInDuration)
        } else if optIn?.pid == clientPID {
            optIn = nil
        }
        let raw = max(0, min(1, level() ?? 0))
        let voice = current == "recording" ? max(0, min(1, energy(raw))) : 0
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

    // MARK: Moving windows

    /// The shortest run of words that has to match before a window is joined
    /// onto the words already shown.
    static let minimumOverlap = 3

    /// Joins a trailing window onto the words already shown. The window's
    /// start is looked for in `shown`, compared without case or punctuation
    /// (a re-decode may spell a boundary word differently); the longest run
    /// wins, the latest on a tie, so a phrase repeated earlier in the take
    /// does not pull the join back. Everything before it stays and the window
    /// replaces the rest (its tail may have been revised). A window that
    /// matches nothing is added after what is shown, so the start of the take
    /// is never lost.
    static func stitch(shown: String, window: String) -> String {
        let old = words(shown), new = words(window)
        let trimmed = window.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty else { return trimmed }
        guard !new.isEmpty else { return shown }
        var best: (start: Int, length: Int)?
        for start in old.indices {
            var length = 0
            while start + length < old.count, length < new.count, old[start + length].key == new[length].key {
                length += 1
            }
            guard length >= min(minimumOverlap, new.count) else { continue }
            if best == nil || length >= best!.length { best = (start, length) }
        }
        guard let best else { return shown + " " + trimmed }
        return String(shown[..<old[best.start].range.lowerBound]) + trimmed
    }

    private static func words(_ text: String) -> [(key: String, range: Range<String.Index>)] {
        var result: [(key: String, range: Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            result.append((text[start..<index].lowercased().filter { $0.isLetter || $0.isNumber }, start..<index))
        }
        return result
    }
}
