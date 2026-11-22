import Foundation

/// What the drops would show: one candidate, and whether Y may save it.
struct DropLearningSuggestion: Equatable {
    let candidate: DropLearningCandidate
    /// Calibration: the drops show, Y saves nothing.
    let dryRun: Bool
}

/// After a delivered Drop take, reads the same field once (5 s later), finds the
/// user's corrections and counts them. A correction seen in two takes within 14
/// days becomes one suggestion. Field text and candidates stay in memory; only
/// salted hashes and day numbers are stored. No model, no network.
/// WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
@MainActor
final class DropLearningCoordinator {
    static let readDelay: Double = 5
    /// Calibration keeps reading until the field holds still this long...
    static let calibrationStableReads = 3
    static let calibrationPollInterval: Double = 1
    /// ...or this much time has passed since the paste.
    static let calibrationMaxSeconds: Double = 30

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
    }

    /// Set by the drops UI; until then suggestions only reach the journal.
    var onSuggestion: ((DropLearningSuggestion) -> Void)?

    private let deps: Dependencies
    private var pending: Task<Void, Never>?

    init(dependencies: Dependencies) { self.deps = dependencies }

    static func live(openVocabulary: @escaping () -> Void) -> DropLearningCoordinator {
        let defaults = UserDefaults.standard
        return DropLearningCoordinator(dependencies: Dependencies(
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
            replacements: DropReplacementStore()
        ))
    }

    private var settings: DropLearningSettings {
        DropLearningSettings(defaults: deps.defaults, now: deps.now, journal: deps.journal)
    }

    /// A new take begins: the previous field may receive it, so the old read
    /// would compare against the wrong text.
    func takeStarted() {
        pending?.cancel()
        pending = nil
    }

    /// Called right after a take reached an external app's field.
    func delivered(_ take: DropLearningTake, targetPID: pid_t?) {
        pending?.cancel()
        pending = nil
        let calibrating = settings.isCalibrating()
        guard settings.isEnabled || calibrating else { return }
        guard let pid = targetPID, let handle = deps.fieldAccess.capture(pid: pid) else {
            if calibrating { deps.journal.append(entry(event: "skipped", take: take, extra: ["reason": "field_not_readable"])) }
            return
        }
        pending = Task { [weak self] in
            await self?.observe(take: take, handle: handle, calibrating: calibrating)
        }
    }

    /// Exposed for tests: waits for the scheduled read.
    func waitForPendingRead() async { await pending?.value }

    private func observe(take: DropLearningTake, handle: DropEditFieldHandle, calibrating: Bool) async {
        do { try await deps.sleep(Self.readDelay) } catch { return }
        guard !Task.isCancelled else { return }
        let first = deps.fieldAccess.read(handle)
        let lists = deps.lists()
        let firstCandidates = first.map {
            DropLearningClassifier.candidates(take: take, field: $0, lists: lists, lexicon: deps.lexicon)
        } ?? []
        guard calibrating else {
            guard first != nil else { return }
            finish(candidates: firstCandidates, ledger: DropLearningLedger(defaults: deps.defaults, now: deps.now), dryRun: false)
            return
        }
        deps.journal.append(entry(event: "read", take: take, extra: [
            "seconds": Self.readDelay, "readable": first != nil, "candidates": describe(firstCandidates),
            "hunks": first.flatMap { describeHunks(take.pasted, $0) } ?? [],
        ]))
        // Calibration: keep reading until the field holds still or 30 s.
        var last = first
        var stable = 0
        var elapsed = Self.readDelay
        while let current = last, stable < Self.calibrationStableReads, elapsed < Self.calibrationMaxSeconds {
            do { try await deps.sleep(Self.calibrationPollInterval) } catch { return }
            guard !Task.isCancelled else { return }
            elapsed += Self.calibrationPollInterval
            let next = deps.fieldAccess.read(handle)
            if next == current { stable += 1 } else { stable = 0 }
            last = next
        }
        let settled = last.map {
            DropLearningClassifier.candidates(take: take, field: $0, lists: deps.lists(), lexicon: deps.lexicon)
        } ?? []
        let ledger = DropLearningLedger(
            defaults: deps.defaults, key: DropLearningSettings.calibrationLedgerKey, now: deps.now
        )
        let ready = finish(candidates: settled, ledger: ledger, dryRun: true)
        deps.journal.append(entry(event: "settled", take: take, extra: [
            "seconds": elapsed, "readable": last != nil, "candidates": describe(settled),
            "hunks": last.flatMap { describeHunks(take.pasted, $0) } ?? [],
            "missedByFirstRead": describe(settled.filter { candidate in
                !firstCandidates.contains { $0.ledgerKey == candidate.ledgerKey }
            }),
            "ready": describe(ready.map { [$0] } ?? []),
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
