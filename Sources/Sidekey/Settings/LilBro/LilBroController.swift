import AppKit
import SwiftUI

/// Whether the little guy runs around Settings (off leaves only the "Lil Bro"
/// entry in the sidebar, which opens the same balloon), and whether his
/// answers come from whytap.ai. Answers are off until the person turns them
/// on in his balloon; until then he finds settings by name on this Mac.
// WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md
@MainActor
final class LilBroPreferences: ObservableObject {
    static let shared = LilBroPreferences()
    static let mascotKey = "lilBro.mascotVisible"
    static let answersKey = "lilBro.answersFromWhytap"

    private let defaults: UserDefaults
    @Published var mascotVisible: Bool {
        didSet { defaults.set(mascotVisible, forKey: Self.mascotKey) }
    }
    @Published var answersFromWhytap: Bool {
        didSet { defaults.set(answersFromWhytap, forKey: Self.answersKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mascotVisible = defaults.object(forKey: Self.mascotKey) as? Bool ?? true
        answersFromWhytap = defaults.object(forKey: Self.answersKey) as? Bool ?? false
    }
}

/// Lil Bro, the guide in the Settings window: where he stands, what he does,
/// and his speech balloon. He walks the window like a map (run, jump, fetch
/// the ladder), punches the row that opens the place he was asked about and
/// opens it through the same calls the row itself makes. While his balloon is
/// open he stands still; he runs home only after it is closed.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md
@MainActor
final class LilBroController: ObservableObject {
    enum Bubble: Equatable {
        case closed
        /// A small tag while he moves or presses: "On my way…".
        case tag(String)
        case thinking
        case full
    }

    struct Turn: Equatable, Identifiable {
        let id = UUID()
        let question: String
        /// Asked with answers from whytap.ai on, so whytap.ai already has it.
        /// Only such turns go back as earlier exchanges; a question asked on
        /// this Mac never leaves it later.
        var sentToWhytap = false
        var reply: LilBroReply?
        /// The place he opened for this answer, said under it.
        var opened: String?
    }

    struct Ladder: Equatable {
        let x: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    @Published private(set) var feet: CGPoint = .zero
    @Published private(set) var segment: LilBroSegment?
    @Published private(set) var pose: LilBroPose = .idle
    @Published private(set) var poseStart = Date()
    @Published private(set) var facingRight = true
    @Published private(set) var ladder: Ladder?
    @Published private(set) var bubble: Bubble = .closed
    @Published private(set) var turns: [Turn] = []
    /// The block he brought the person to, outlined.
    @Published private(set) var target: CGRect?
    /// The row he is punching, lit for the moment of the hit.
    @Published private(set) var flash: CGRect?
    @Published private(set) var placed = false
    @Published var hovering = false
    @Published var showEarlier = false
    @Published var menuOpen = false
    /// The disclosure before answers from whytap.ai, asked for from ⋯.
    @Published private(set) var consentShown = false
    @Published var draft = ""

    private(set) var map = LilBroMap()
    private(set) var busy = false
    /// The spot he stands at after guiding, until the balloon closes.
    private var holding = false
    private var job: Task<Void, Never>?
    private var wander: Task<Void, Never>?
    private var nextStroll = Date.distantPast

    let selection: SettingsWindowSelection
    let preferences: LilBroPreferences
    /// Finds settings by name on this Mac; used while answers are off.
    let local: LilBroBrain
    /// whytap.ai; asked only while answers are on.
    let remote: LilBroBrain
    private let reduceMotion: () -> Bool
    private let sleep: (TimeInterval) async -> Void
    private let now: () -> Date

    init(selection: SettingsWindowSelection,
         preferences: LilBroPreferences? = nil,
         local: LilBroBrain? = nil,
         remote: LilBroBrain? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1e9)) },
         now: @escaping () -> Date = Date.init) {
        self.selection = selection
        self.preferences = preferences ?? .shared
        self.local = local ?? LilBroLocalGuide()
        self.remote = remote ?? LilBroRemoteBrain()
        self.reduceMotion = reduceMotion
        self.sleep = sleep
        self.now = now
    }

    var mascotVisible: Bool { preferences.mascotVisible }
    var answersFromWhytap: Bool { preferences.answersFromWhytap }
    var isOpen: Bool { bubble != .closed }
    var isBusy: Bool { busy }

    /// The pose to draw: a wave while the pointer is over him at rest.
    var shownPose: LilBroPose {
        hovering && pose == .idle && segment == nil && canCatch ? .hover : pose
    }

    func position(at date: Date) -> CGPoint {
        segment?.position(at: date) ?? feet
    }

    // MARK: The map

    func update(spots: [LilBroSpot: CGRect]) {
        map.spots = spots
        mapChanged()
    }

    func update(blocks: [CGRect]) {
        map.blocks = blocks
        mapChanged()
    }

    func update(bounds: CGRect) {
        map.bounds = bounds
        mapChanged()
    }

    private func mapChanged() {
        guard map.home != nil else { return }
        if !placed {
            placed = true
            feet = map.homeStand
            return
        }
        guard !busy, segment == nil else { return }
        if holding {
            // He stays with the block he brought the person to; if it
            // scrolled away, he waits at home.
            if let target, map.platforms.contains(where: { abs($0.minY - target.minY) < 1 && abs($0.minX - target.minX) < 1 }) {
                return
            }
            if let moved = nearestPlatform(to: target) {
                target = moved
                feet = LilBroPlanner.perch(on: moved)
            } else {
                holding = false
                target = nil
                feet = map.homeStand
                setPose(.idle)
            }
            return
        }
        // At home: keep standing on the entry when the window resizes.
        if let home = map.home, abs(feet.y - (home.minY + 1)) > 2 || feet.x < home.minX || feet.x > home.maxX {
            feet = CGPoint(x: min(max(feet.x, home.minX + 16), home.maxX - 14), y: home.minY + 1)
        }
    }

    private func nearestPlatform(to rect: CGRect?) -> CGRect? {
        guard let rect else { return nil }
        return map.platforms
            .filter { abs($0.minX - rect.minX) < 2 && abs($0.width - rect.width) < 2 }
            .min { abs($0.minY - rect.minY) < abs($1.minY - rect.minY) }
    }

    // MARK: What the person does

    /// Whether a click on him opens the balloon: whenever it is closed, even
    /// while he strolls or walks home (that stops).
    var canCatch: Bool { bubble == .closed }
    var reducesMotion: Bool { reduceMotion() }

    /// A click on him: a surprised hop, then the balloon.
    func catchHim() {
        guard canCatch else { return }
        cancelJob()
        setPose(.caught)
        job = Task { [weak self] in
            guard let self else { return }
            await sleep(reduceMotion() ? 0 : 0.44)
            guard !Task.isCancelled else { return }
            setPose(.idle)
            bubble = .full
            job = nil
        }
    }

    /// The sidebar entry: opens or closes the balloon.
    func toggleFromSidebar() {
        if bubble == .closed { openBalloon() } else { close() }
    }

    /// Every way the full balloon opens: he stops where he is first, so he
    /// never runs under an open message.
    private func openBalloon() {
        cancelJob()
        setPose(.idle)
        bubble = .full
    }

    func close() {
        cancelJob()
        bubble = .closed
        menuOpen = false
        showEarlier = false
        target = nil
        holding = false
        guard mascotVisible else { return }
        // Only now, with the balloon gone, he runs home.
        job = Task { [weak self] in
            await self?.goHome()
            guard !Task.isCancelled else { return }
            self?.job = nil
        }
    }

    func clear() {
        turns = []
        menuOpen = false
        showEarlier = false
    }

    /// ⋯ → Turn on answers: shows the disclosure; nothing is turned on yet.
    // WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md
    func askToTurnOnAnswers() {
        menuOpen = false
        guard !answersFromWhytap else { return }
        consentShown = true
    }

    /// The disclosure's Turn on answers button — the only way answers from
    /// whytap.ai are turned on. Nothing is sent before it.
    func turnOnAnswers() {
        preferences.answersFromWhytap = true
        consentShown = false
        menuOpen = false
        objectWillChange.send()
    }

    /// The disclosure's Not now.
    func dismissConsent() {
        consentShown = false
    }

    /// ⋯ → Turn off answers from whytap.ai.
    func turnOffAnswers() {
        preferences.answersFromWhytap = false
        consentShown = false
        menuOpen = false
        objectWillChange.send()
    }

    func setMascotVisible(_ visible: Bool) {
        cancelJob()
        preferences.mascotVisible = visible
        menuOpen = false
        holding = false
        target = nil
        feet = map.homeStand
        setPose(.idle)
    }

    /// Sends the draft or a suggested question.
    func ask(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        menuOpen = false
        showEarlier = false
        cancelJob()
        let remoteOn = answersFromWhytap
        let asked = LilBroQuestion(text: question, screen: remoteOn ? screen : "", history: remoteOn ? history : [])
        turns.append(Turn(question: question, sentToWhytap: remoteOn && LilBroRemoteBrain.sends(question)))
        let index = turns.count - 1
        bubble = .thinking
        busy = true
        target = nil
        if mascotVisible { setPose(.think) }
        let brain = remoteOn ? remote : local
        job = Task { [weak self] in
            guard let self else { return }
            let reply = await brain.reply(to: asked)
            guard !Task.isCancelled, index < turns.count else { return }
            turns[index].reply = reply
            switch reply {
            case .answer(let answer):
                if let destination = answer.destination {
                    await guide(to: destination)
                    // Said only once the place is really open.
                    guard !Task.isCancelled else { return }
                    turns[index].opened = destination.title
                }
            case .offline, .unavailable, .limit, .unknown:
                if mascotVisible { setPose(.sad) }
            }
            guard !Task.isCancelled else { return }
            busy = false
            bubble = .full
            announce(turns[index])
            job = nil
        }
    }

    /// Asks the last question again in its place (after offline or an error).
    func retry() {
        guard !busy, let last = turns.last else { return }
        turns.removeLast()
        ask(last.question)
    }

    /// A page he offers when whytap.ai cannot answer: he runs there and opens it.
    func open(_ destination: LilBroDestination) {
        guard !busy else { return }
        menuOpen = false
        cancelJob()
        busy = true
        let index = turns.indices.last
        job = Task { [weak self] in
            guard let self else { return }
            await guide(to: destination)
            guard !Task.isCancelled else { return }
            if let index, index < turns.count { turns[index].opened = destination.title }
            busy = false
            bubble = .full
            job = nil
        }
    }

    /// The screen he is asked from, as the server reads it: `tab` or `tab/feature`.
    var screen: String {
        let tab = selection.selectedTab.resolved.rawValue
        if selection.selectedTab.resolved == .features, let feature = selection.shownFeature {
            return "\(tab)/\(feature.rawValue)"
        }
        return tab
    }

    /// Up to three earlier exchanges answered by whytap.ai, oldest first.
    /// Questions asked while answers were off stay on this Mac.
    var history: [LilBroQuestion.Exchange] {
        turns.compactMap { turn in
            guard turn.sentToWhytap, case .answer(let answer) = turn.reply else { return nil }
            return LilBroQuestion.Exchange(question: turn.question,
                                           answer: (answer.paragraphs + answer.bullets).joined(separator: "\n"))
        }.suffix(3).map { $0 }
    }

    // MARK: Guiding

    /// One press on the way: the row he punches and what it opens.
    struct Stop {
        let spot: LilBroSpot
        let press: @MainActor () -> Void
    }

    func stops(for destination: LilBroDestination) -> [Stop] {
        let selection = selection
        switch destination {
        case .feature(let feature):
            if selection.selectedTab == .features, selection.shownFeature == feature { return [] }
            var stops: [Stop] = []
            if selection.selectedTab != .features || selection.shownFeature != nil {
                stops.append(Stop(spot: .tab(.features)) { selection.select(.features) })
            }
            stops.append(Stop(spot: .feature(feature)) { selection.open(feature) })
            return stops
        case .tab(let tab):
            if selection.selectedTab == tab.resolved, tab.resolved != .features || selection.shownFeature == nil { return [] }
            return [Stop(spot: .tab(tab.resolved)) { selection.select(tab) }]
        case .apiKeys:
            return [Stop(spot: .tab(.apiAndModels)) { selection.showAPIKeys() }]
        }
    }

    private func guide(to destination: LilBroDestination) async {
        let stops = stops(for: destination)
        // WHY: a closed balloon or a new question cancels this job; after every
        // wait it checks before pressing a row or moving him, so a cancelled
        // guide never navigates.
        guard mascotVisible, !reduceMotion() else {
            guard !Task.isCancelled else { return }
            stops.forEach { $0.press() }
            await settle()
            guard !Task.isCancelled else { return }
            if mascotVisible { arrive() }
            return
        }
        bubble = .tag("On my way…")
        for stop in stops {
            guard !Task.isCancelled else { return }
            if let rect = await visibleSpot(stop.spot) {
                guard !Task.isCancelled else { return }
                await walk(to: LilBroPlanner.perch(on: rect))
                guard !Task.isCancelled else { return }
                await punch(rect)
            }
            guard !Task.isCancelled else { return }
            stop.press()
            await settle()
        }
        guard !Task.isCancelled else { return }
        if let block = firstPaneBlock() {
            await walk(to: LilBroPlanner.perch(on: block))
            guard !Task.isCancelled else { return }
            target = block
            holding = true
        }
        setPose(.point)
    }

    /// Reduced motion or no mascot: he appears on the block he opened.
    private func arrive() {
        guard let block = firstPaneBlock() else { return }
        feet = LilBroPlanner.perch(on: block)
        target = block
        holding = true
        setPose(.point)
    }

    /// The first block of the screen now in the pane.
    private func firstPaneBlock() -> CGRect? {
        guard let pane = map.spots[.pane] else { return nil }
        return map.platforms.filter { pane.contains(CGPoint(x: $0.midX, y: $0.minY + 1)) }
            .min { $0.minY < $1.minY }
    }

    /// Waits a moment for the screen to report the spot after a change.
    private func visibleSpot(_ spot: LilBroSpot) async -> CGRect? {
        for _ in 0..<8 {
            if let rect = map.visible(spot) { return rect }
            await sleep(0.05)
            if Task.isCancelled { return nil }
        }
        return nil
    }

    /// Lets a new screen lay out and report its blocks.
    private func settle() async {
        await sleep(0.3)
    }

    func walk(to goal: CGPoint, stroll: Bool = false) async {
        var moves = LilBroPlanner.route(from: feet, to: goal, in: map, reduceMotion: reduceMotion())
        if stroll, moves.count == 1, case .run(let to, _) = moves[0] { moves = [.run(to: to, stroll: true)] }
        for move in moves {
            guard !Task.isCancelled else { return }
            await perform(move)
        }
        if !Task.isCancelled { setPose(.idle) }
    }

    private func perform(_ move: LilBroMove) async {
        switch move {
        case .run(let to, let stroll):
            face(to.x)
            setPose(stroll ? .walk : .run)
            await animate(.run(from: feet, to: to, stroll: stroll, at: now()))
        case .jump(let to):
            face(to.x)
            setPose(.jump)
            await animate(.jump(from: feet, to: to, at: now()))
            guard !Task.isCancelled else { return }
            setPose(.land)
            await sleep(0.12)
        case .ladder(let from, let to):
            facingRight = true
            ladder = Ladder(x: from.x + 2, top: to.y - 5, bottom: from.y)
            setPose(.prop)
            await sleep(0.28)
            guard !Task.isCancelled else { return }
            setPose(.climb)
            await animate(.climb(from: from, to: to, at: now()))
            guard !Task.isCancelled else { return }
            ladder = nil
            setPose(.idle)
            await sleep(0.15)
        case .appear(let point):
            feet = point
        }
    }

    private func animate(_ next: LilBroSegment) async {
        segment = next
        await sleep(next.duration)
        // Cancelled: whoever cancelled already stopped him where he was and
        // may have started a new move; this one touches nothing.
        guard !Task.isCancelled else { return }
        feet = next.to
        segment = nil
    }

    /// Two little punches at a row, then it is pressed.
    private func punch(_ rect: CGRect) async {
        face(rect.midX >= feet.x - 1 ? feet.x + 1 : feet.x - 1)
        setPose(.hit)
        flash = rect
        await sleep(0.43)
        guard !Task.isCancelled else { return }
        flash = nil
        setPose(.idle)
    }

    func goHome() async {
        guard mascotVisible, let home = map.home else { return }
        busy = true
        let stand = abs(feet.y - (home.minY + 1)) < 3
            ? CGPoint(x: min(max(feet.x, home.minX + 16), home.maxX - 14), y: home.minY + 1)
            : map.homeStand
        await walk(to: stand)
        // A cancelled walk home leaves `busy` to the job that replaced it.
        guard !Task.isCancelled else { return }
        busy = false
        facingRight = true
    }

    // MARK: Idle life

    /// Now and then, alone at home, he strolls along his entry.
    func startWandering(random: @escaping (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) {
        wander?.cancel()
        nextStroll = now().addingTimeInterval(random(4...9))
        wander = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard mascotVisible, placed, !busy, !holding, !hovering, bubble == .closed, segment == nil,
                      job == nil || job?.isCancelled == true, !reduceMotion(),
                      now() >= nextStroll, let home = map.home else { continue }
                nextStroll = now().addingTimeInterval(random(9...18))
                let x = home.minX + 16 + CGFloat(random(0...1)) * max(10, home.width - 30)
                stroll(to: CGPoint(x: x, y: home.minY + 1))
            }
        }
    }

    /// A slow walk along his entry, as its own job: anything else cancels it.
    func stroll(to point: CGPoint) {
        job = Task { [weak self] in
            await self?.walk(to: point, stroll: true)
            guard !Task.isCancelled else { return }
            self?.job = nil
        }
    }

    func stopWandering() {
        wander?.cancel()
        wander = nil
        cancelJob()
    }

    // MARK: Helpers

    private func cancelJob() {
        job?.cancel()
        job = nil
        if let segment {
            feet = segment.position(at: now())
            self.segment = nil
        }
        ladder = nil
        flash = nil
        busy = false
    }

    private func setPose(_ next: LilBroPose) {
        if pose != next || next == .caught {
            pose = next
            poseStart = now()
        }
    }

    private func face(_ x: CGFloat) {
        if abs(x - feet.x) > 2 { facingRight = x > feet.x }
    }

    private func announce(_ turn: Turn) {
        guard let reply = turn.reply else { return }
        let text: String
        switch reply {
        case .answer(let answer): text = answer.paragraphs.joined(separator: " ")
        case .unknown: text = LilBroCopy.unknown
        case .offline: text = LilBroCopy.offline
        case .unavailable: text = LilBroCopy.unavailable
        case .limit: text = LilBroCopy.limit
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// Lil Bro's fixed words, in one place for the view and the tests.
enum LilBroCopy {
    static let greeting = "Hi, I’m Lil Bro. Ask me where anything is in Settings — I’ll run there and open it for you."
    static let greetingAnswers = "Hi, I’m Lil Bro. Ask me anything about Whytap — I’ll open the right setting for you."
    static let localNote = "Answers come from this Mac: I find settings by name."
    /// Said once, before anything is sent, with the button that turns answers on.
    static let offer = "Want real answers? Each question you ask here then goes to whytap.ai (Claude Haiku 5.5) with the Settings screen you’re on and up to three of your earlier whytap.ai questions with its answers, sent again. whytap.ai keeps each question, those earlier questions and answers, and its reply for 90 days, without your address. Keys, dictated text and your settings stay on this Mac."
    static let turnOn = "Turn on answers"
    static let answersNote = "Questions go to whytap.ai (Claude Haiku 5.5) with the screen you’re on and up to three earlier whytap.ai questions and answers; it keeps them 90 days. Keys and dictated text stay on your Mac."
    static let notNow = "Not now"
    static let unknown = "I only know Settings by name. Try one of these:"
    static let offline = "I can’t reach whytap.ai — no internet. Settings still work offline; this is the closest page:"
    static let unavailable = "whytap.ai can’t answer right now. Settings still work; this is the closest page:"
    static let limit = "I’ve answered as many questions as I can today. I’ll be back tomorrow. Settings still work — closest pages:"
    static let catchMe = "Catch me"
    static let placeholder = "Ask Lil Bro…"
}
