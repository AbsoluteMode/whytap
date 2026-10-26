import AppKit
import SwiftUI

struct MeetingAssistantQuestion: Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var question: String
    var conclusion = ""
    var points: [String] = []
    var followups: [MeetingAssistantContinuation] = []
    var sources: [String] = []
}
struct MeetingAssistantContinuation: Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var title: String
}
struct MeetingScreenshot: Identifiable {
    let id = UUID()
    let image: NSImage
    let payload: MeetingAssistantImage
}

@MainActor
final class MeetingAssistantModel: ObservableObject {
    @Published var pending: [MeetingAssistantQuestion] = []
    @Published var completed: [MeetingAssistantQuestion] = []
    @Published var selected: MeetingAssistantQuestion?
    @Published var selectedRootID: String?
    @Published var busy: String?
    @Published var answerVisible = false
    @Published var visible = false
    @Published var draft = ""
    @Published var followupDraft = ""
    @Published var previous: [MeetingAssistantQuestion] = []
    @Published var screenshots: [MeetingScreenshot] = []
    @Published var previewScreenshot: MeetingScreenshot?
    @Published var screenBusy = false
    @Published var screenError = ""
    @Published var notice = ""
    @Published var spaces: [MeetingSpace] = []
    @Published var selectedSpaceID = ""
    @Published var spaceError = ""
    @Published var editing = false
    @Published var audioConnecting = false
    @Published private(set) var startRequested = false
    @Published var listening = false
    @Published var releasingAudio = false
    @Published var audioIssue = ""
    @Published var screenshotProtected = false
    @Published var questionsHeight: CGFloat = 160
    @Published var layoutHeight: CGFloat = 1000
    @Published var bodyLimit: CGFloat = 250
    var onChange: (() -> Void)?
    private(set) var transcript = ""
    private var sessions: [String: Session] = [:]
    private var threads: [String: [MeetingAssistantQuestion]] = [:]
    private var request: Task<Void, Never>?
    private var captureRequest: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var catalogGeneration = UUID()
    private var detectionTask: Task<Void, Never>?
    private var detectionTimer: Task<Void, Never>?
    private var generation = UUID()
    private var captureGeneration = UUID()
    private var listeningGeneration = UUID()
    private var lastAnalyzed = ""
    private var seen: [String] = []
    private var suspended = false
    private var suppressedForMeeting = false
    private let directory: URL
    private let defaults: UserDefaults
    private let runner: MeetingAssistantRunner
    private let detectionInterval: Duration
    private let meetingScope: MeetingAssistantMeetingScope?
    private let routesConfigured: @MainActor () -> Bool
    let audio: MeetingAssistantAudio
    private let capture: AgentScreenCapture
    static let screenshotLimit = 6

    struct Session {
        var pending: [MeetingAssistantQuestion]; var completed: [MeetingAssistantQuestion]
        var selected: MeetingAssistantQuestion?; var root: String?; var previous: [MeetingAssistantQuestion]
        var threads: [String: [MeetingAssistantQuestion]]; var draft: String; var followup: String; var notice: String
    }

    init(directory: URL = MeetingSpace.directory, defaults: UserDefaults = .standard,
         runner: MeetingAssistantRunner? = nil, audio: MeetingAssistantAudio? = nil, capture: AgentScreenCapture? = nil,
         detectionInterval: Duration = .seconds(4), meetingScope: MeetingAssistantMeetingScope? = nil,
         routesConfigured: @escaping @MainActor () -> Bool = {
             [AIFeature.meetingAssistant, .meetingAssistantAudio].allSatisfy {
                 AIRoutingStore.shared.route(for: $0)?.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
             }
         }) {
        self.directory = directory; self.defaults = defaults; self.runner = runner ?? MeetingAssistantRunner()
        self.detectionInterval = detectionInterval
        self.meetingScope = meetingScope; self.routesConfigured = routesConfigured
        self.audio = audio ?? MeetingAssistantAudio()
        self.capture = capture ?? AgentScreenCapture(capture: AgentScreenCapture.captureForMeeting)
        selectedSpaceID = defaults.string(forKey: "meetingAssistant.selectedSpace") ?? ""
        self.audio.onText = { [weak self] text in self?.transcript = text }
        self.audio.onState = { [weak self] active, issue in
            guard let self else { return }
            self.mutate { self.listening = active; self.audioConnecting = active && !self.audio.ready; if let issue { self.audioIssue = issue } }
            if issue != nil { self.suppressedForMeeting = true }
            if !active { self.detectionTask?.cancel(); self.detectionTask = nil; self.detectionTimer?.cancel(); self.detectionTimer = nil }
        }
        self.meetingScope?.onStart = { [weak self] in
            guard let self else { return }
            self.suppressedForMeeting = false
            if !self.listening { self.mutate { self.startRequested = true } }
        }
        self.meetingScope?.onEnd = { [weak self] in
            guard let self else { return }
            self.suppressedForMeeting = false
            self.stopListening()
            self.mutate { self.audioIssue = "Встреча закончилась — слушание выключено." }
        }
    }

    var currentSpace: MeetingSpace? { spaces.first { $0.id == selectedSpaceID } }
    var hoverState: MeetingAssistantHoverState {
        .init(available: currentSpace != nil && routesConfigured(), meetingActive: meetingScope?.isMeetingActive == true, phase: releasingAudio ? .stopping :
                startRequested || audioConnecting ? .connecting : listening ? .listening : .off)
    }
    var animation: Animation? { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.25) }
    func mutate(_ action: () -> Void) { withAnimation(animation, action); onChange?() }

    func show() {
        mutate { visible = true }
        prepare()
    }

    /// Configured models enable automatic listening on each recognized meeting.
    /// Catalog/probe work is passive until a meeting actually becomes active.
    // WHY: docs/decisions/2026-10-26-meeting-assistant-auto-listen.md
    func prepare() {
        suspended = false
        guard catalogTask == nil else { return }
        catalogTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reloadSpaces()
                guard self != nil else { return }
                if let self, !self.visible && !self.routesConfigured() {
                    self.catalogTask = nil
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func configurationChanged() {
        reconcileMeetingListening()
        if !suspended { prepare() }
    }

    private func reconcileMeetingListening() {
        guard !suspended else { return }
        guard currentSpace != nil, routesConfigured() else {
            meetingScope?.stop()
            if listening || startRequested { stopListening(clearContext: true) }
            return
        }
        meetingScope?.begin()
        if meetingScope?.isMeetingActive == true, !suppressedForMeeting, !listening {
            startRequested = true
        }
    }

    func reloadSpaces() async {
        catalogGeneration = UUID(); let catalogToken = catalogGeneration
        defer {
            if !Task.isCancelled, catalogGeneration == catalogToken {
                reconcileMeetingListening()
            }
            if startRequested, !releasingAudio, !suspended, !Task.isCancelled, catalogGeneration == catalogToken {
                startRequested = false
                startListening()
                onChange?()
            }
        }
        let directory = self.directory
        do {
            let catalog = try await Task.detached { try MeetingSpace.load(directory: directory) }.value
            guard !Task.isCancelled, catalogGeneration == catalogToken else { return }
            let message = catalog.invalidFiles.isEmpty ? "" : "Некоторые Spaces не загрузились. Попроси Codex или Claude Code проверить каталог."
            guard catalog.spaces != spaces || message != spaceError else { return }
            let old = currentSpace
            let validIDs = Set(catalog.spaces.map(\.id))
            let unchangedIDs = Set(spaces.filter { previous in catalog.spaces.contains(previous) }.map(\.id))
            sessions = sessions.filter { validIDs.contains($0.key) && unchangedIDs.contains($0.key) }
            if let old, catalog.spaces.first(where: { $0.id == old.id }) != old {
                cancelWork(); stopListening(clearContext: true); sessions.removeValue(forKey: old.id); clearConversation()
            }
            mutate {
                spaces = catalog.spaces
                spaceError = message
                if !validIDs.contains(selectedSpaceID) { selectedSpaceID = spaces.first?.id ?? "" }
            }
        } catch {
            guard !Task.isCancelled, catalogGeneration == catalogToken else { return }
            let message = "Не удалось прочитать каталог Spaces. Проверь его через Codex или Claude Code."
            guard !spaces.isEmpty || spaceError != message else { return }
            cancelWork(); stopListening(clearContext: true)
            mutate { spaces = []; sessions = [:]; clearConversation(); spaceError = message }
        }
    }

    func selectSpace(_ id: String) {
        guard id != selectedSpaceID, spaces.contains(where: { $0.id == id }) else { return }
        cancelWork(); stopListening(clearContext: true)
        sessions[selectedSpaceID] = Session(pending: pending, completed: completed, selected: selected, root: selectedRootID,
            previous: previous, threads: threads, draft: draft, followup: followupDraft, notice: notice)
        mutate {
            clearConversation(); selectedSpaceID = id
            if let state = sessions[id] {
                pending = state.pending; completed = state.completed; selected = state.selected
                selectedRootID = state.root; previous = state.previous; threads = state.threads
                draft = state.draft; followupDraft = state.followup; notice = state.notice
                answerVisible = selected != nil
            }
        }
        defaults.set(id, forKey: "meetingAssistant.selectedSpace")
    }

    private func clearConversation() {
        pending = []; completed = []; selected = nil; selectedRootID = nil
        previous = []; threads = [:]; draft = ""; followupDraft = ""; notice = ""
        answerVisible = false; screenshots = []; previewScreenshot = nil; screenError = ""
    }

    func ask(_ question: MeetingAssistantQuestion) {
        if let turns = threads[question.id], let latest = turns.last {
            cancelAnswer()
            mutate { selectedRootID = question.id; selected = latest; previous = Array(turns.dropLast()); notice = ""; answerVisible = true }
            return
        }
        run(question: question, root: question.id, continuation: false)
    }

    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 4_000 else { mutate { notice = "Сократи вопрос до 4000 символов."; answerVisible = true }; return }
        let question = MeetingAssistantQuestion(question: text)
        mutate { pending.insert(question, at: 0); pending = Array(pending.prefix(5)); draft = "" }
        ask(question)
    }
    func submitFollowup() {
        let text = followupDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000, let root = selectedRootID else { return }
        followupDraft = ""
        run(question: .init(question: text), root: root, continuation: true)
    }
    func follow(_ item: MeetingAssistantContinuation) { followupDraft = item.title; submitFollowup() }

    private func run(question: MeetingAssistantQuestion, root: String, continuation: Bool) {
        guard let space = currentSpace else { mutate { notice = "Выбери готовый Space. Его может создать Codex или Claude Code."; answerVisible = true }; return }
        cancelAnswer()
        let token = generation
        var prior = threads[root] ?? []
        if continuation, let selected, let index = prior.firstIndex(where: { $0.id == selected.id }) {
            prior = Array(prior.prefix(index + 1))
        }
        let images = screenshots, context = transcript
        let history = prior.suffix(6).map { NativeAgentConversation.Pair(user: $0.question, assistant: $0.conclusion + "\n" + $0.points.joined(separator: "\n")) }
        mutate { selectedRootID = root; selected = question; previous = continuation ? prior : []; busy = question.id; notice = ""; answerVisible = true }
        request = Task { [weak self, runner] in
            do {
                let answer = try await runner.answer(question: question.question, space: space, transcript: context, history: history, images: images.map(\.payload))
                guard !Task.isCancelled, let self, self.generation == token, self.currentSpace == space else { return }
                var delivered = question
                delivered.conclusion = answer.conclusion; delivered.points = answer.points
                delivered.followups = answer.followups.map { .init(title: $0) }; delivered.sources = answer.sources
                self.mutate {
                    self.busy = nil; self.selected = delivered
                    self.threads[root] = Array((prior + [delivered]).suffix(20))
                    if !continuation {
                        self.pending.removeAll { $0.id == root }
                        self.completed.insert(delivered, at: 0); self.completed = Array(self.completed.prefix(20))
                        let roots = Set(self.completed.map(\.id)); self.threads = self.threads.filter { roots.contains($0.key) }
                    }
                    let sent = Set(images.map(\.id)); self.screenshots.removeAll { sent.contains($0.id) }
                    if let id = self.previewScreenshot?.id, sent.contains(id) { self.previewScreenshot = nil }
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.mutate {
                    self.busy = nil
                    self.notice = error is FeatureRouteError ? "Выбери провайдера и модель Meeting Assistant в API & Models."
                        : ((error as? LocalizedError)?.errorDescription ?? "Не удалось получить ответ. Проверь настройки модели и повтори.")
                }
            }
        }
    }

    private func cancelAnswer() { generation = UUID(); request?.cancel(); request = nil; busy = nil }
    func cancel() { cancelAnswer(); mutate { notice = "Ответ отменён. Можно повторить вопрос." } }
    func back() {
        guard let answer = previous.popLast() else { return }
        cancelAnswer(); mutate { selected = answer; notice = "" }
    }
    func restoreAnswer() { mutate { answerVisible = selected != nil || !notice.isEmpty } }

    func lookAtScreen() {
        guard !screenBusy, screenshots.count < Self.screenshotLimit else { return }
        let token = captureGeneration
        mutate { screenBusy = true; screenError = "" }
        captureRequest = Task { [weak self, capture] in
            let response = await capture.handle([:])
            guard !Task.isCancelled, let self, self.captureGeneration == token else { return }
            self.mutate {
                self.screenBusy = false
                guard response.ok, let object = response.data.object, let encoded = object["image"]?.string,
                      let data = Data(base64Encoded: encoded), let image = NSImage(data: data), self.screenshots.count < Self.screenshotLimit else {
                    self.screenError = "Не удалось прикрепить скрин. Проверь разрешение на запись экрана и повтори."; return
                }
                self.screenshots.append(MeetingScreenshot(image: image, payload: .init(data: data, mimeType: "image/jpeg")))
            }
        }
    }
    func removeScreenshot(_ id: UUID) {
        mutate { screenshots.removeAll { $0.id == id }; if previewScreenshot?.id == id { previewScreenshot = nil }; screenError = "" }
    }
    private func cancelWork() {
        let wasBusy = busy != nil
        cancelAnswer(); if wasBusy { notice = "Ответ отменён. Повтори вопрос." }
        captureGeneration = UUID(); captureRequest?.cancel(); captureRequest = nil
        screenBusy = false; screenshots = []; previewScreenshot = nil
    }
    func dismiss() {
        cancelWork()
        if !routesConfigured() { catalogTask?.cancel(); catalogTask = nil }
        mutate { visible = false; editing = false; notice = selected?.conclusion.isEmpty == true ? "Ответ отменён. Повтори вопрос." : notice }
    }
    func suspend() {
        suspended = true; catalogGeneration = UUID()
        cancelWork(); stopListening(clearContext: true); meetingScope?.stop()
        catalogTask?.cancel(); catalogTask = nil
        mutate { visible = false; editing = false }
    }
    func setMeetingEnabled(_ enabled: Bool) {
        guard enabled else {
            suppressedForMeeting = true
            if listening || startRequested { stopListening() }
            return
        }
        guard !listening, !startRequested, !releasingAudio else { return }
        // Revalidate the Space before a hover start, including after the panel
        // was closed and its catalog watcher stopped. The catalog loop owns it.
        suppressedForMeeting = false
        mutate { startRequested = true }
        show()
    }
    func startListening() {
        guard currentSpace != nil, !listening, !releasingAudio else { return }
        do { _ = try runner.resolve() } catch {
            suppressedForMeeting = true
            mutate { audioIssue = "Настрой модель Meeting Assistant в API & Models." }
            return
        }
        transcript = ""; lastAnalyzed = ""; audioIssue = ""
        seen = (pending + completed).map(\.question)
        listeningGeneration = UUID(); let token = listeningGeneration
        audio.start()
        detectionTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.detectionInterval ?? .seconds(4))
                guard !Task.isCancelled else { return }
                self?.detectQuestions(token: token)
            }
        }
    }
    func stopListening(clearContext: Bool = false) {
        let needsRelease = releasingAudio || audio.active
        startRequested = false
        listeningGeneration = UUID()
        let releaseToken = listeningGeneration
        if needsRelease { releasingAudio = true }
        let cleanup = audio.cancel()
        if needsRelease {
            Task { [weak self] in
                await cleanup.value
                guard let self, self.listeningGeneration == releaseToken else { return }
                self.mutate { self.releasingAudio = false }
            }
        }
        detectionTask?.cancel(); detectionTask = nil; detectionTimer?.cancel(); detectionTimer = nil
        if clearContext { transcript = ""; lastAnalyzed = ""; seen = [] }
    }
    private func detectQuestions(token: UUID) {
        guard listening, listeningGeneration == token, detectionTask == nil, busy == nil,
              transcript.count >= 20, transcript != lastAnalyzed else { return }
        let text = transcript, seen = self.seen
        lastAnalyzed = text
        detectionTask = Task { [weak self, runner] in
            defer { if self?.listeningGeneration == token { self?.detectionTask = nil } }
            do {
                let questions = try await runner.questions(transcript: text, seen: seen)
                guard !Task.isCancelled, let self, self.listeningGeneration == token else { return }
                self.mutate {
                    if self.audioIssue.hasPrefix("Модель не разобрала") { self.audioIssue = "" }
                    for text in questions where !self.seen.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                        self.pending.insert(.init(question: text), at: 0); self.seen.append(text)
                    }
                    self.pending = Array(self.pending.prefix(5)); self.seen = Array(self.seen.suffix(80))
                }
            } catch {
                guard !Task.isCancelled, let self, self.listeningGeneration == token else { return }
                if error is MeetingQuestionError {
                    self.mutate { self.audioIssue = "Модель не разобрала последнюю фразу. Слушаю дальше; можно задать вопрос вручную." }
                    return
                }
                self.suppressedForMeeting = true
                self.stopListening()
                self.mutate { self.audioIssue = "Не удалось выделить вопросы. Проверь модель Meeting Assistant и подключись снова." }
            }
        }
    }
}
