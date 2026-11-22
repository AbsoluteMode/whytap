import AppKit

/// What the drops would show: one candidate, and whether Y may save it.
struct DropLearningSuggestion: Equatable {
    let candidate: DropLearningCandidate
    /// Calibration: the drops show, Y saves nothing.
    let dryRun: Bool
}

/// After a delivered Drop take, watches the same field until the user sends
/// or clears it, leaves it, starts another take, or 2 minutes pass, and keeps
/// the last text that still holds the take. That text is compared with what
/// was pasted: a correction seen in two takes within 14 days becomes one
/// suggestion. Field text stays in memory; only salted hashes and day numbers
/// are stored. No keystrokes are recorded, no model, no network.
/// WHY: .project-docs/decisions/2026-11-22-drop-edit-observation.md
@MainActor
final class DropLearningCoordinator {
    /// Reads between AX notifications: apps that send none, a missed one.
    static let pollInterval: Double = 0.5
    /// The paste must show up in the field this soon, or it is not watched.
    static let alignSeconds: Double = 5
    /// The longest a field is watched after a paste.
    static let maxObserveSeconds: Double = 120
    /// Return may send the message: the field is read again this soon after.
    static let returnSettleSeconds: Double = 0.15
    /// A tree an app exposed for a take is turned off if no paste follows
    /// (the longest take plus its delivery).
    static let leaseSeconds: Double = 660

    /// Why watching a field ended.
    enum EndReason: String {
        /// Sent or emptied: the text before it counts.
        case cleared
        /// Focus left the field or it went away: the last text counts.
        case focusLeft, removed
        case timeout
        /// Another take starts: the last text counts before the new paste.
        case newTake
        /// The text no longer holds the take (a rewrite or another message).
        case rewritten
        /// The paste never showed up, or the field could not be read.
        case notPasted, unreadable
        /// Learning (or calibration) was switched off.
        case switchedOff

        var counts: Bool {
            switch self {
            case .cleared, .focusLeft, .removed, .timeout, .newTake: return true
            case .rewritten, .notPasted, .unreadable, .switchedOff: return false
            }
        }
    }

    /// Suggestions in the order one take offers them; one per take.
    static func priority(_ candidate: DropLearningCandidate) -> Int {
        switch candidate {
        case .vocabAdd: return 0
        case .replaceAdd: return 1
        case .fillerRemove: return 2
        case .fillerAdd: return 3
        case .replaceRemove: return 4
        case .vocabRemove: return 5
        case .vocabFull: return 6
        }
    }

    struct Dependencies {
        var fieldAccess: DropEditFieldAccess
        var lexicon: DropWordLexicon
        var defaults: UserDefaults
        var now: () -> Date
        var journal: DropLearningJournal
        var lists: () -> DropLearningLists
        var sleep: (Double) async throws -> Void
        /// The island is idle (no take, agent or failure on screen).
        var isIdle: () -> Bool
        var openVocabulary: () -> Void
        var vocabulary: VocabularyCache
        var fillers: FillerTermsStore
        var replacements: DropReplacementStore
        /// Calls back on Return or Enter while a field is watched; carries no
        /// key data. Returns the stop.
        var watchReturn: (@escaping @MainActor () -> Void) -> () -> Void = { _ in {} }
        /// Monotonic seconds for the watch deadlines.
        var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        /// The target app's bundle ID, for the developer journal only.
        var appID: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    }

    /// Set by the drops UI; until then suggestions only reach the journal.
    var onSuggestion: ((DropLearningSuggestion) -> Void)?

    private final class Observation {
        let take: DropLearningTake
        let handle: DropEditFieldHandle
        /// Learning is off and calibration on: counters of its own, Y saves
        /// nothing.
        let calibrating: Bool
        /// Calibration is on: the developer journal gets an entry.
        let journaling: Bool
        let app: String?
        let startedAt: TimeInterval
        var elapsed: Double = 0
        var reads = 0
        /// The first text that held the take: what the field showed once the
        /// paste was there. Corrections already in it are not the user's
        /// edits of this take (memory only).
        var firstAligned: String?
        /// The last text that still held the take (memory only).
        var lastAligned: String?
        var watch: DropEditFieldWatch?
        var stopReturn: (() -> Void)?
        var task: Task<Void, Never>?
        var returnRead: Task<Void, Never>?

        init(take: DropLearningTake, handle: DropEditFieldHandle, calibrating: Bool, journaling: Bool,
             app: String?, startedAt: TimeInterval) {
            self.take = take
            self.handle = handle
            self.calibrating = calibrating
            self.journaling = journaling
            self.app = app
            self.startedAt = startedAt
        }
    }

    private let deps: Dependencies
    private var observation: Observation?
    private var lease: DropEditAccessibilityLease?
    private var leaseTimer: Task<Void, Never>?
    private var maintenanceTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(dependencies: Dependencies) { self.deps = dependencies }

    /// The app's coordinator. Calibration expiry and opt-out cleanup run at
    /// launch and every hour, not only when another take is delivered.
    static func live(openVocabulary: @escaping () -> Void) -> DropLearningCoordinator {
        let defaults = UserDefaults.standard
        let coordinator = DropLearningCoordinator(dependencies: Dependencies(
            fieldAccess: AXDropEditFieldAccess(),
            lexicon: SystemWordLexicon(),
            defaults: defaults,
            now: Date.init,
            journal: .production,
            lists: {
                DropLearningLists(
                    vocabulary: VocabularyCache.shared.terms,
                    fillers: FillerTermsStore().terms(),
                    replacements: DropReplacementStore().replacements()
                )
            },
            sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
            isIdle: { AppState.shared.phase == .idle },
            openVocabulary: openVocabulary,
            vocabulary: .shared,
            fillers: FillerTermsStore(),
            replacements: DropReplacementStore(),
            watchReturn: DropLearningReturnKey.watch
        ))
        coordinator.performMaintenance()
        coordinator.maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.performMaintenance() }
        }
        // Quitting mid-watch must not leave another app's tree turned on.
        coordinator.observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.stopWatching() }
        })
        // The switch only writes a preference: turning learning off ends the
        // watch and any exposure right away, not at the next take.
        coordinator.observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.settingsChanged() }
        })
        return coordinator
    }

    /// Learning and calibration both off: nothing is watched or exposed, and
    /// the reason counters are deleted.
    func settingsChanged() {
        guard !capturesFields else { return }
        if observation != nil || lease != nil { stopWatching() }
        if deps.defaults.object(forKey: DropLearningStats.key) != nil { stats.clear() }
    }

    private var stats: DropLearningStats { DropLearningStats(defaults: deps.defaults) }

    /// Stops any watch without learning from it and undoes any exposure.
    func stopWatching() {
        end(.switchedOff)
        releaseLease()
    }

    /// Ends calibration that expired or was switched off, deleting its
    /// journal and counters. WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
    func performMaintenance() {
        _ = settings.isCalibrating()
    }

    /// Is this kind of read still wanted? Checked before every read and every
    /// journal write, so switching it off stops a field being watched.
    private func stillWanted(calibrating: Bool) -> Bool {
        calibrating ? settings.isCalibrating() : settings.isEnabled
    }

    private var settings: DropLearningSettings {
        DropLearningSettings(defaults: deps.defaults, now: deps.now, journal: deps.journal)
    }

    /// Learning or calibration is on: only then is the field captured at the
    /// paste boundary. With both off the paste path is untouched.
    var capturesFields: Bool { settings.isEnabled || settings.isCalibrating() }

    /// A new take begins. The field being watched counts with the text it
    /// holds now, before the new paste can land in it. The target app is
    /// asked to expose its fields if it does not yet (Electron, web views),
    /// so the field can be captured at the paste a few seconds later.
    func takeStarted(targetPID: pid_t? = nil) {
        end(.newTake, keepLease: true)
        guard capturesFields, let pid = targetPID else {
            releaseLease()
            return
        }
        if lease?.pid != pid {
            releaseLease()
            lease = deps.fieldAccess.exposeFields(pid: pid)
        }
        leaseTimer?.cancel()
        leaseTimer = nil
        guard lease != nil else { return }
        leaseTimer = Task { [weak self] in
            do { try await self?.deps.sleep(Self.leaseSeconds) } catch { return }
            guard let self, !Task.isCancelled, self.observation == nil else { return }
            self.releaseLease()
        }
    }

    /// Called right before Cmd+V: the target app's focused field, if learning
    /// is on and the gate allows it. Reads no text.
    func prepareDelivery(targetPID: pid_t?) -> DropEditFieldHandle? {
        pendingTarget = nil
        guard capturesFields, let pid = targetPID else { return nil }
        let handle = deps.fieldAccess.capture(pid: pid)
        pendingTarget = (pid, handle == nil ? deps.fieldAccess.lastRefusal ?? "noCapture" : nil)
        return handle
    }

    /// The target of the last capture and why it failed, for the reason
    /// counters and the developer journal.
    private var pendingTarget: (pid: pid_t, refusal: String?)?

    /// Called right after the take reached an external app. The field
    /// captured before Cmd+V must still be that app's focused field; a field
    /// focused during the paste delay is never read.
    func delivered(_ take: DropLearningTake, handle: DropEditFieldHandle?) {
        end(.newTake, keepLease: true)
        let target = pendingTarget
        pendingTarget = nil
        let journaling = settings.isCalibrating()
        let learning = settings.isEnabled
        // Calibration alone is a dry run; with learning on it only adds the
        // developer journal to real learning.
        // WHY: .project-docs/decisions/2026-11-22-drop-learning-cut-tail.md
        let calibrating = journaling && !learning
        guard learning || journaling else { return releaseLease() }
        let app = (handle?.pid ?? target?.pid).flatMap(deps.appID)
        guard let handle, deps.fieldAccess.isStillFocused(handle) else {
            let refusal = handle == nil ? target?.refusal ?? "noCapture" : "focusMovedBeforePaste"
            stats.add(["watch.noField", "field." + refusal])
            if journaling {
                deps.journal.append(entry(event: "skipped", take: take, extra: ["reason": refusal, "app": app ?? "-"]))
            }
            return releaseLease()
        }
        stats.add(["watch.started"])
        let observation = Observation(take: take, handle: handle, calibrating: calibrating, journaling: journaling,
                                      app: app, startedAt: deps.clock())
        self.observation = observation
        leaseTimer?.cancel()
        leaseTimer = nil
        observation.watch = deps.fieldAccess.watch(handle) { [weak self, weak observation] change in
            guard let self, let observation else { return }
            switch change {
            case .value, .focusLeft: self.sample(observation)
            case .removed: if self.observation === observation { self.end(.removed) }
            }
        }
        observation.stopReturn = deps.watchReturn { [weak self, weak observation] in
            guard let self, let observation else { return }
            self.returnPressed(observation)
        }
        observation.task = Task { [weak self, weak observation] in
            guard let observation else { return }
            await self?.poll(observation)
        }
    }

    /// Exposed for tests: waits until the field is no longer watched.
    func waitForObservation() async {
        while let task = observation?.task {
            await task.value
            if observation?.task == task { break }
        }
    }

    /// Return or Enter in the watched app: the message may be on its way.
    /// The text is read now and again a moment later; Return itself is never
    /// held or changed.
    private func returnPressed(_ observation: Observation) {
        sample(observation)
        guard self.observation === observation else { return }
        observation.returnRead?.cancel()
        observation.returnRead = Task { [weak self, weak observation] in
            do { try await self?.deps.sleep(Self.returnSettleSeconds) } catch { return }
            guard let self, let observation, !Task.isCancelled else { return }
            self.sample(observation)
        }
    }

    private func poll(_ observation: Observation) async {
        while self.observation === observation {
            sample(observation)
            guard self.observation === observation else { return }
            do { try await deps.sleep(Self.pollInterval) } catch {
                if self.observation === observation { end(.unreadable) }
                return
            }
            guard self.observation === observation, !Task.isCancelled else { return }
        }
    }

    /// One bounded read of the watched field. Every path (poll, AX
    /// notification, Return) checks the deadlines first, on the clock.
    private func sample(_ observation: Observation) {
        guard self.observation === observation else { return }
        guard stillWanted(calibrating: observation.calibrating) else { return end(.switchedOff) }
        observation.elapsed = max(0, deps.clock() - observation.startedAt)
        if observation.elapsed >= Self.maxObserveSeconds { return end(.timeout) }
        if observation.lastAligned == nil, observation.elapsed >= Self.alignSeconds { return end(.notPasted) }
        let text: String
        switch deps.fieldAccess.read(observation.handle) {
        case .text(let value): text = value
        // Focus verifiably moved: the last text counts.
        case .focusLeft: return end(.focusLeft)
        // Same field, but no read now: what was kept is not trusted.
        case .unreadable: return end(.unreadable)
        }
        observation.reads += 1
        if DropEditDiff.diff(pasted: observation.take.pasted, field: text) != nil {
            if observation.firstAligned == nil { observation.firstAligned = text }
            observation.lastAligned = text
            return
        }
        // Until the paste lands the field may still hold its old text.
        guard observation.lastAligned != nil else { return }
        end(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .cleared : .rewritten)
    }

    private func releaseLease() {
        leaseTimer?.cancel()
        leaseTimer = nil
        lease?.release()
        lease = nil
    }

    /// Stops watching and, when the reason counts, learns from the last text
    /// that held the take.
    private func end(_ reason: EndReason, keepLease: Bool = false) {
        guard let observation else { return }
        self.observation = nil
        observation.watch?.cancel()
        observation.stopReturn?()
        observation.task?.cancel()
        observation.returnRead?.cancel()
        if !keepLease { releaseLease() }
        let calibrating = observation.calibrating
        guard stillWanted(calibrating: calibrating) else { return }
        let field = reason.counts ? observation.lastAligned : nil
        let lists = deps.lists()
        // Why this take did or did not teach anything, as reason names only.
        var notes = ["end." + reason.rawValue]
        if reason.counts, field == nil { notes.append("end.neverAligned") }
        let classify = { (text: String, note: (String) -> Void) in
            DropLearningClassifier.candidates(take: observation.take, field: text, lists: lists,
                                              lexicon: self.deps.lexicon, note: note)
        }
        var candidates = field.map { classify($0) { notes.append($0) } } ?? []
        // Only corrections made while watching: text already in the field
        // when it first held the take (a draft, a paste that never landed)
        // is not this take's edit.
        if let first = observation.firstAligned, !candidates.isEmpty {
            let before = Set(classify(first) { _ in }.map(\.ledgerKey))
            let count = candidates.count
            candidates.removeAll { before.contains($0.ledgerKey) }
            notes += Array(repeating: "candidate.alreadyInField", count: count - candidates.count)
        }
        notes += candidates.map { "candidate." + $0.kind }
        let ledger = calibrating
            ? DropLearningLedger(defaults: deps.defaults, key: DropLearningSettings.calibrationLedgerKey, now: deps.now)
            : DropLearningLedger(defaults: deps.defaults, now: deps.now)
        let ready = field == nil ? nil : finish(candidates: candidates, ledger: ledger, dryRun: calibrating)
        var shown = "none"
        if ready != nil {
            shown = deps.isIdle() ? "suggested" : "suggestion.waitsForIdle"
            notes.append(shown)
        }
        stats.add(notes)
        // The developer journal holds the words of the edit: only while
        // calibration is on, on this Mac, deleted after 14 days.
        guard observation.journaling, settings.isCalibrating() else { return }
        deps.journal.append(entry(event: "observed", take: observation.take, extra: [
            "app": observation.app ?? "-", "dryRun": calibrating,
            "reason": reason.rawValue, "seconds": observation.elapsed, "reads": observation.reads,
            "readable": observation.lastAligned != nil, "notes": notes, "candidates": describe(candidates),
            "counts": candidates.map { ledger.count($0) }, "threshold": DropLearningLedger.threshold,
            "hunks": field.flatMap { describeHunks(observation.take.pasted, $0) } ?? [],
            "ready": describe(ready.map { [$0] } ?? []), "shown": shown,
        ]))
    }

    @discardableResult
    private func finish(candidates: [DropLearningCandidate], ledger: DropLearningLedger, dryRun: Bool) -> DropLearningCandidate? {
        let ready = ledger.observe(candidates)
        guard let best = ready.min(by: { Self.priority($0) < Self.priority($1) }) else { return nil }
        // Never over another take, an agent answer or a failure: it waits for
        // the next time the same correction is seen.
        guard deps.isIdle() else { return best }
        onSuggestion?(DropLearningSuggestion(candidate: best, dryRun: dryRun))
        return best
    }

    // MARK: - Answers from the drops

    /// Y. Saves through the same stores the Vocab and Filler editors use.
    func accept(_ suggestion: DropLearningSuggestion) {
        ledger(for: suggestion).reset(suggestion.candidate)
        guard !suggestion.dryRun else { return }
        switch suggestion.candidate {
        case .vocabAdd(let term): deps.vocabulary.add(term)
        case .vocabRemove(let term): deps.vocabulary.remove(term)
        case .replaceAdd(let rule): deps.replacements.add(rule)
        case .replaceRemove(let rule): deps.replacements.remove(heard: rule.heard)
        case .fillerAdd(let term): deps.fillers.add(term)
        case .fillerRemove(let term): deps.fillers.remove(term)
        case .vocabFull: deps.openVocabulary()
        }
    }

    /// N: never offered again.
    func decline(_ suggestion: DropLearningSuggestion) {
        ledger(for: suggestion).decline(suggestion.candidate)
    }

    /// Shown for 10 s and let go: counting starts over.
    func expired(_ suggestion: DropLearningSuggestion) {
        ledger(for: suggestion).reset(suggestion.candidate)
    }

    private func ledger(for suggestion: DropLearningSuggestion) -> DropLearningLedger {
        DropLearningLedger(
            defaults: deps.defaults,
            key: suggestion.dryRun ? DropLearningSettings.calibrationLedgerKey : DropLearningLedger.key,
            now: deps.now
        )
    }

    // MARK: - Calibration journal

    private func entry(event: String, take: DropLearningTake, extra: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: deps.now()),
            "event": event,
            "mode": take.mode.rawValue,
            "translated": take.translated,
            "vocabTransport": String(describing: take.vocabTransport),
            "pastedWords": DropEditToken.tokenize(take.pasted).count,
        ]
        for (key, value) in extra { result[key] = value }
        return result
    }

    private func describe(_ candidates: [DropLearningCandidate]) -> [[String: String]] {
        candidates.map { candidate in
            switch candidate {
            case .vocabAdd(let term): return ["kind": "vocab+", "term": term]
            case .vocabRemove(let term): return ["kind": "vocab-", "term": term]
            case .replaceAdd(let rule): return ["kind": "replace+", "heard": rule.heard, "wanted": rule.wanted]
            case .replaceRemove(let rule): return ["kind": "replace-", "heard": rule.heard, "wanted": rule.wanted]
            case .fillerAdd(let term): return ["kind": "filler+", "term": term]
            case .fillerRemove(let term): return ["kind": "filler-", "term": term]
            case .vocabFull(let term, let usage):
                return ["kind": "vocabFull", "term": term, "usage": "\(usage.used)/\(usage.limit)"]
            }
        }
    }

    private func describeHunks(_ pasted: String, _ field: String) -> [[String: String]]? {
        DropEditDiff.diff(pasted: pasted, field: field)?.hunks.map {
            ["removed": DropLearningClassifier.phrase($0.removed), "inserted": DropLearningClassifier.phrase($0.inserted)]
        }
    }
}

/// Return and Enter while a field is watched: a listen-only global key
/// monitor that looks only at the key code and keeps nothing. It is installed
/// for one observation (at most 2 minutes) and removed after.
/// WHY: .project-docs/decisions/2026-11-22-drop-edit-observation.md
enum DropLearningReturnKey {
    static let keyCodes: Set<UInt16> = [36, 76] // kVK_Return, kVK_ANSI_KeypadEnter

    @MainActor
    static func watch(_ onReturn: @escaping @MainActor () -> Void) -> () -> Void {
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard keyCodes.contains(event.keyCode) else { return }
            MainActor.assumeIsolated { onReturn() }
        }
        return { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
