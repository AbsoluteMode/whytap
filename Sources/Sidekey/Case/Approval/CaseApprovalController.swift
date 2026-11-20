import Foundation

/// Queue of Case Approve prompts shown in the island, one at a time (FIFO).
///
/// Each prompt ignores keys and clicks until the keyboard has been quiet for
/// `armingDelay`: every key press seen while it is unarmed starts the wait
/// again, so a person typing in another app cannot answer it by accident. It is
/// denied as `.timedOut` after `timeout`. A prompt whose client went away (the
/// broker task is cancelled) is withdrawn and denied, never granted. After a
/// timed answer, waiting prompts of the same app and project are allowed by
/// that grant instead of being shown. The key tap exists only while the queue
/// is non-empty; without it (no Accessibility) the prompt is answered by click.
@MainActor
final class CaseApprovalController: ObservableObject, CaseApprovalPresenting {
    static let armingDelay: TimeInterval = 0.3
    static let timeout: TimeInterval = 60

    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    /// The prompt on screen.
    @Published private(set) var current: CaseApprovalRequest?
    /// Whether the visible prompt accepts answers yet.
    @Published private(set) var isArmed = false
    /// Prompts waiting behind the visible one.
    @Published private(set) var pendingCount = 0
    /// When the visible prompt is denied without an answer.
    @Published private(set) var deadline: Date?
    /// False when the key tap could not be installed; the prompt then works by click.
    @Published private(set) var keysAvailable = true
    /// Changes with every prompt shown, so the view starts each one fresh.
    @Published private(set) var promptSerial = 0
    @Published private(set) var isEditingMinutes = false
    @Published private(set) var selectedTimedMinutes = CaseVaultPayload.defaultTimedApprovalMinutes

    private struct Entry {
        let id: UUID
        let request: CaseApprovalRequest
        let continuation: CheckedContinuation<CaseApprovalOutcome, Never>
    }

    private let keyTap: CaseApprovalKeyIntercepting
    private let now: () -> Date
    private let schedule: Schedule
    private var active: Entry?
    private var queue: [Entry] = []
    private var cancelArming: (() -> Void)?
    private var cancelTimeout: (() -> Void)?
    private var tapRunning = false

    init(keyTap: CaseApprovalKeyIntercepting? = nil,
         now: @escaping () -> Date = Date.init,
         schedule: Schedule? = nil) {
        self.keyTap = keyTap ?? CaseApprovalKeyTap()
        self.now = now
        self.schedule = schedule ?? { delay, work in
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        }
    }

    /// Visible plus waiting prompts.
    var queuedCount: Int { (active == nil ? 0 : 1) + queue.count }

    /// The temporary Bypass answer exists only for a positive N.
    var offersTimed: Bool { (current?.timedMinutes ?? 0) > 0 }

    func requestApproval(_ r: CaseApprovalRequest) async -> CaseApprovalOutcome {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // A client that left before its prompt was queued is never asked about.
                if Task.isCancelled {
                    continuation.resume(returning: .deny)
                    return
                }
                queue.append(Entry(id: id, request: r, continuation: continuation))
                if active == nil {
                    showNext()
                } else {
                    pendingCount = queue.count
                }
            }
        } onCancel: {
            // Runs after the entry is queued: both hop through the main actor in order.
            Task { @MainActor [weak self] in self?.withdraw(id) }
        }
    }

    /// A click on one of the prompt's buttons. Ignored until the prompt is armed.
    func choose(_ outcome: CaseApprovalOutcome) {
        guard acceptsAnswer else { return }
        if case .allowTimed(let minutes) = outcome {
            guard offersTimed, CaseViewModel.timedApprovalRange.contains(minutes) else { return }
        }
        resolve(outcome)
    }

    func setTimedMinutes(_ minutes: Int) {
        guard active != nil, CaseViewModel.timedApprovalRange.contains(minutes) else { return }
        selectedTimedMinutes = minutes
    }

    /// Editing the duration must never consume Y/N/A/Escape as approval answers.
    func setEditingMinutes(_ editing: Bool) {
        guard active != nil, offersTimed else { return }
        isEditingMinutes = editing
        keyTap.setArmed(isArmed && !editing)
    }

    /// Answers the visible prompt and shows the next one.
    func resolve(_ outcome: CaseApprovalOutcome) {
        guard let entry = active else { return }
        clearTimers()
        active = nil
        isEditingMinutes = false
        entry.continuation.resume(returning: outcome)
        if case .allowTimed(let minutes) = outcome, CaseViewModel.timedApprovalRange.contains(minutes) {
            allowWaiting(coveredBy: entry.request)
        }
        if queue.isEmpty {
            current = nil
            isArmed = false
            deadline = nil
            pendingCount = 0
            stopTap()
        } else {
            showNext()
        }
    }

    /// Denies every prompt, visible and waiting (app quit).
    func cancelAll() {
        let waiting = queue
        queue.removeAll()
        resolve(.deny)
        for entry in waiting { entry.continuation.resume(returning: .deny) }
    }

    /// A key press seen by the tap while the prompt is not armed yet: the person
    /// is typing, so the quiet period starts over.
    func noteTyping() {
        guard active != nil, !isArmed else { return }
        scheduleArming()
    }

    // MARK: - Private

    /// The prompt's client disconnected: deny it without showing or granting anything.
    private func withdraw(_ id: UUID) {
        if active?.id == id {
            resolve(.deny)
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            let entry = queue.remove(at: index)
            pendingCount = queue.count
            entry.continuation.resume(returning: .deny)
        }
    }

    /// Waiting prompts of the app and project that just got a timed grant are
    /// covered by it, so they are allowed instead of asking again.
    private func allowWaiting(coveredBy granted: CaseApprovalRequest) {
        guard let appID = granted.appID, let projectID = granted.projectID else { return }
        let covered = queue.filter { $0.request.appID == appID && $0.request.projectID == projectID }
        guard !covered.isEmpty else { return }
        queue.removeAll { $0.request.appID == appID && $0.request.projectID == projectID }
        pendingCount = queue.count
        for entry in covered { entry.continuation.resume(returning: .allow) }
    }

    /// Armed only by the arming timer, which fires after `armingDelay` without key presses.
    private var acceptsAnswer: Bool { active != nil && isArmed }

    private func handleKey(_ key: CaseApprovalKey) {
        guard !isEditingMinutes else { return }
        switch key {
        case .yes: choose(.allow)
        case .no, .escape: choose(.deny)
        case .timed: choose(.allowTimed(minutes: selectedTimedMinutes))
        }
    }

    private func showNext() {
        guard !queue.isEmpty else { return }
        let entry = queue.removeFirst()
        active = entry
        let shown = now()
        isArmed = false
        isEditingMinutes = false
        pendingCount = queue.count
        deadline = shown.addingTimeInterval(Self.timeout)
        promptSerial += 1
        current = entry.request
        selectedTimedMinutes = entry.request.timedMinutes
        startTapIfNeeded()
        keyTap.setArmed(false)
        // Timers carry their prompt's serial, so a late one never touches the next prompt.
        let serial = promptSerial
        cancelTimeout = schedule(Self.timeout) { [weak self] in
            guard let self, self.promptSerial == serial else { return }
            self.resolve(.timedOut)
        }
        scheduleArming()
    }

    /// (Re)starts the quiet period after which the visible prompt accepts answers.
    private func scheduleArming() {
        cancelArming?()
        let serial = promptSerial
        cancelArming = schedule(Self.armingDelay) { [weak self] in
            guard let self, self.active != nil, self.promptSerial == serial else { return }
            self.isArmed = true
            self.keyTap.setArmed(!self.isEditingMinutes)
        }
    }

    private func startTapIfNeeded() {
        guard !tapRunning else { return }
        do {
            try keyTap.start(
                onKey: { [weak self] key in self?.handleKey(key) },
                onUnarmedKeyDown: { [weak self] in self?.noteTyping() })
            tapRunning = true
            keysAvailable = true
        } catch {
            keysAvailable = false
        }
    }

    private func stopTap() {
        keyTap.setArmed(false)
        guard tapRunning else { return }
        keyTap.stop()
        tapRunning = false
    }

    private func clearTimers() {
        cancelArming?()
        cancelTimeout?()
        cancelArming = nil
        cancelTimeout = nil
    }
}

/// The same island prompt and queue ask whether a coding harness may use
/// Whytap: one prompt at a time, the same quiet-keyboard arming and timeout.
// WHY: .project-docs/decisions/2026-11-20-harness-access.md
extension CaseApprovalController: HarnessAccessPresenting {
    func requestAccess(for client: HarnessClient) async -> HarnessAccessOutcome {
        var request = CaseApprovalRequest(
            appName: client.name, projectName: "", keyNames: [], command: "", timedMinutes: 0)
        request.harness = client
        switch await requestApproval(request) {
        case .allow, .allowTimed: return .allow
        case .deny: return .deny
        case .timedOut: return .timedOut
        }
    }
}
