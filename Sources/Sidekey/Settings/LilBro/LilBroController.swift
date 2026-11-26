import AppKit
import SwiftUI

/// Whether the little guy runs around Settings (off leaves only the "Lil Bro"
/// entry in the sidebar, which opens the same balloon). His answers always
/// come from whytap.ai (Claude Sonnet 5.5): there is no switch to turn them
/// off (the maintainer's decision, REV 13).
// WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md
@MainActor
final class LilBroPreferences: ObservableObject {
    static let shared = LilBroPreferences()
    static let mascotKey = "lilBro.mascotVisible"

    private let defaults: UserDefaults
    @Published var mascotVisible: Bool {
        didSet { defaults.set(mascotVisible, forKey: Self.mascotKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mascotVisible = defaults.object(forKey: Self.mascotKey) as? Bool ?? true
    }
}

/// Lil Bro, the guide in the Settings window: where he stands, what he does,
/// and his speech balloon. Every question goes to whytap.ai; when the model
/// says the person asked to go somewhere, he walks the window like a map
/// (run, jump, fetch the ladder), punches the row that opens that place and
/// opens it through the same calls the row itself makes. Otherwise the answer
/// stays in the balloon. No scripted scenarios: he presses no setup step and
/// offers no ready-made questions. While his balloon is open he stands still;
/// he runs home only after it is closed.
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
    /// The current answer's details (more words, the place he opened,
    /// follow-up questions): hidden until asked for.
    @Published var showMore = false
    @Published var menuOpen = false

    private(set) var map = LilBroMap()
    /// The row he led to (REV 12) while its tab shows it as focused: the
    /// outline is that row's current place, gone while it is scrolled away
    /// and back when it returns. Cleared with the focus (another tab, Clear,
    /// a new question, closing).
    // WHY: .project-docs/decisions/2026-11-24-lil-bro.md (builder review of #493, ticket 627)
    private(set) var leadRow: LilBroRow?
    private(set) var busy = false
    /// The spot he stands at after guiding, until the balloon closes.
    private var holding = false
    private var job: Task<Void, Never>?
    private var wander: Task<Void, Never>?
    private var nextStroll = Date.distantPast

    let selection: SettingsWindowSelection
    let preferences: LilBroPreferences
    /// whytap.ai, which answers every question.
    let remote: LilBroBrain
    private let reduceMotion: () -> Bool
    private let sleep: (TimeInterval) async -> Void
    private let now: () -> Date

    init(selection: SettingsWindowSelection,
         preferences: LilBroPreferences? = nil,
         remote: LilBroBrain? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1e9)) },
         now: @escaping () -> Date = Date.init) {
        self.selection = selection
        self.preferences = preferences ?? .shared
        self.remote = remote ?? LilBroRemoteBrain()
        self.reduceMotion = reduceMotion
        self.sleep = sleep
        self.now = now
    }

    var mascotVisible: Bool { preferences.mascotVisible }
    var isOpen: Bool { bubble != .closed }
    /// Opened before any question, only the greeting and the reply field
    /// show; the balloon appears with the first answer.
    var showsBalloon: Bool { !turns.isEmpty }
    /// The line he greets with over the field, a different one each opening.
    private(set) var greeting = LilBroCopy.greetings[0]
    private var opened = 0

    private func nextGreeting() {
        greeting = LilBroCopy.greetings[opened % LilBroCopy.greetings.count]
        opened += 1
    }
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
        if let row = leadRow {
            followLeadRow(row)
            return
        }
        if holding {
            // He stays with the block he brought the person to; if it
            // scrolled away, he waits at home.
            if let target, let same = map.platforms.first(where: { abs($0.minY - target.minY) < 1 && abs($0.minX - target.minX) < 1 }) {
                // A last half-point of scrolling: the outline follows, he stays.
                if same != target { self.target = same }
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

    /// The outline is the led row's place now; with the little guy he stands
    /// on it while it shows, waits at home while it is scrolled away and is
    /// back on it when it returns, for as long as the lead lasts (builder
    /// review of #493, ticket 630).
    private func followLeadRow(_ row: LilBroRow) {
        guard leadIsActive(row) else { return endLead() }
        let rect = map.visible(.row(row.id))
        if target != rect { target = rect }
        guard mascotVisible else { return }
        if let rect {
            let perch = LilBroPlanner.perch(on: rect)
            if abs(perch.y - feet.y) >= 1 || abs(perch.x - feet.x) >= 1 { feet = perch }
            if !holding {
                holding = true
                setPose(.point)
            }
        } else if holding {
            holding = false
            feet = map.homeStand
            setPose(.idle)
        }
    }

    /// The row is still the focused one on its own screen (tab, feature
    /// screen, Keys & models section or Toolbox pane).
    private func leadIsActive(_ row: LilBroRow) -> Bool {
        selection.focusedRow == row.id && row.isShown(on: selection.lilBroScreen)
    }

    /// Ends a row lead: no outline; with the little guy he goes back home.
    private func endLead() {
        guard leadRow != nil else { return }
        leadRow = nil
        target = nil
        if holding {
            holding = false
            if mascotVisible {
                feet = map.homeStand
                setPose(.idle)
            }
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
            nextGreeting()
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
        nextGreeting()
        bubble = .full
    }

    func close() {
        cancelJob()
        selection.focusedRow = nil
        leadRow = nil
        // A question closed before its reply came is dropped, not left empty.
        if let last = turns.last, last.reply == nil { turns.removeLast() }
        // The next question starts a new conversation: earlier turns stay
        // under Earlier but are not sent again (REV 21: a cached answer can
        // serve it, and no old exchanges ride on every call).
        historyStart = turns.count
        bubble = .closed
        menuOpen = false
        showEarlier = false
        showMore = false
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

    /// ⋯ → Clear: also ends a question still on its way and the guide, so
    /// no late reply lands and the entry stays usable (builder review of
    /// #493, ticket 625).
    func clear() {
        stopPending()
        turns = []
        historyStart = 0
        menuOpen = false
        showEarlier = false
        showMore = false
    }

    /// Ends the question on its way and any guiding: no late reply, no
    /// navigation. He stays where he is with the balloon open.
    private func stopPending() {
        let pending = busy || bubble == .thinking
        cancelJob()
        selection.focusedRow = nil
        endLead()
        guard pending else { return }
        target = nil
        holding = false
        if bubble != .closed { bubble = .full }
        if mascotVisible { setPose(.idle) }
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

    /// Sends the typed question to whytap.ai. Under the three characters it
    /// takes, nothing is sent and the reply says so.
    // WHY: .project-docs/decisions/2026-11-24-lil-bro.md (REV 10, REV 13)
    func ask(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        menuOpen = false
        showEarlier = false
        showMore = false
        cancelJob()
        target = nil
        selection.focusedRow = nil
        leadRow = nil
        guard LilBroRemoteBrain.sends(question) else {
            turns.append(Turn(question: question, reply: .tooShort))
            if mascotVisible { setPose(.idle) }
            bubble = .full
            announce(turns[turns.count - 1])
            return
        }
        let asked = LilBroQuestion(text: question, screen: screen, history: history,
                                   status: statusProvider?() ?? LilBroStatus())
        turns.append(Turn(question: question))
        let index = turns.count - 1
        bubble = .thinking
        busy = true
        if mascotVisible { setPose(.think) }
        let brain = remote
        job = Task { [weak self] in
            guard let self else { return }
            // Checked again right before it leaves: a question cleared
            // meanwhile sends nothing.
            guard !Task.isCancelled, index < turns.count else { return }
            let reply = await brain.reply(to: asked)
            // A reply after Clear or a new question is ignored.
            guard !Task.isCancelled, index < turns.count else { return }
            turns[index].reply = reply
            switch reply {
            case .answer(let answer):
                // A place only when the model said the person asked for it.
                if let destination = answer.destination {
                    let lead = lead(to: destination)
                    let arrived = await guide(to: lead.destination)
                    // Said only once the place is really open.
                    guard !Task.isCancelled else { return }
                    if arrived { turns[index].opened = lead.opened }
                } else if mascotVisible {
                    // Answered in words: he stays where he is.
                    setPose(.idle)
                }
            case .offline, .unavailable, .limit, .tooShort:
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

    /// The screen he is asked from, as the server reads it: `tab` or `tab/feature`.
    var screen: String { selection.lilBroScreen }

    /// What is wrong on this Mac when he is asked (REV 17); the Settings
    /// window sets it from the same models its screens show.
    var statusProvider: (@MainActor () -> LilBroStatus)?

    /// Where the conversation since the balloon last opened begins in `turns`.
    private(set) var historyStart = 0

    /// Up to three earlier exchanges answered by whytap.ai since the balloon
    /// last opened, oldest first.
    // WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md (REV 21)
    var history: [LilBroQuestion.Exchange] {
        turns.dropFirst(min(historyStart, turns.count)).compactMap { turn in
            guard case .answer(let answer) = turn.reply else { return nil }
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

    /// Where he really leads for an answer and what he then says he opened.
    /// Case, Notify and Monitor act as their pane opens (Case asks for
    /// Touch ID, Notify marks notices read, Monitor polls servers), so he
    /// never opens them: he outlines All tools, and the person clicks the
    /// tool there (builder ticket 658). Their pane already open is shown as
    /// any other.
    // WHY: .project-docs/decisions/2026-11-24-lil-bro.md (builder ticket 658)
    func lead(to destination: LilBroDestination) -> (destination: LilBroDestination, opened: String) {
        if case .row(let row) = destination, let tool = row.tool, tool.paneActsOnOpen,
           !row.isShown(on: selection.lilBroScreen), let tools = LilBroRow.named("toolbox.allTools") {
            return (.row(tools), "\(tools.title): click \(row.title) there to open it")
        }
        return (destination, destination.title)
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
            guard let keys = LilBroRow.named("apiAndModels.apiKeys") else { return [] }
            return stops(for: .row(keys))
        case .row(let row):
            // The tab's sidebar row, or the way to the feature's screen, as a
            // person would click them; the row itself is scrolled to and
            // outlined after it opens (REV 14).
            if let feature = row.feature { return stops(for: .feature(feature)) }
            if row.isShown(on: selection.lilBroScreen) { return [] }
            // From another tab: the sidebar row that opens the tab first
            // (Features for Toolbox, General for Backup and Integrations).
            let tab = row.tab.resolved
            var stops: [Stop] = []
            if selection.selectedTab != tab {
                stops.append(Stop(spot: .tab(tab.sidebarHome)) { selection.select(row.tab) })
            }
            // Then, as a person would, a Toolbox tool's tile or a Keys &
            // models section's tab at the top; Keys & models opens on Models
            // (builder tickets 651, 658).
            if let tool = row.tool {
                stops.append(Stop(spot: .part(row.screen)) { selection.focus(tool) })
            } else if let section = row.apiSection,
                      selection.selectedTab == tab ? selection.apiSection != section : section != .models {
                stops.append(Stop(spot: .part(row.screen)) { selection.apiSection = section })
            }
            return stops
        }
    }

    /// Runs there and opens it. False when a row could not be shown (the
    /// person left its tab meanwhile, or it never appeared): nothing is
    /// outlined, their tab stays, and the row is not said to be opened.
    @discardableResult
    private func guide(to destination: LilBroDestination) async -> Bool {
        let stops = stops(for: destination)
        var row: LilBroRow?
        if case .row(let led) = destination { row = led }
        // WHY: a closed balloon or a new question cancels this job; after every
        // wait it checks before pressing a row or moving him, so a cancelled
        // guide never navigates.
        guard mascotVisible, !reduceMotion() else {
            guard !Task.isCancelled else { return false }
            stops.forEach { $0.press() }
            // Any change after his presses is the person's, even one that
            // comes back to where he went (builder ticket 663).
            let expected = selection.changes
            await settle()
            guard !Task.isCancelled else { return false }
            guard selection.changes == expected else { return personMoved(row) }
            // Without the little guy only a row he was asked about is
            // outlined; he never moves.
            guard mascotVisible || row != nil else { return true }
            let block = await landing(for: destination, expected: expected)
            guard !Task.isCancelled else { return false }
            guard selection.changes == expected else { return personMoved(row) }
            guard let block else { return row == nil }
            if let row { leadRow = row }
            target = block
            if mascotVisible {
                feet = LilBroPlanner.perch(on: block)
                holding = true
                setPose(.point)
            }
            return true
        }
        bubble = .tag("On my way…")
        // Where the window is as far as he knows; a click of the person's
        // own during his run or punch changes it, even one that comes back
        // to where it was, and then he presses nothing more (builder review
        // of #493, tickets 631 and 658).
        var expected = selection.changes
        for stop in stops {
            guard !Task.isCancelled else { return false }
            if let rect = await visibleSpot(stop.spot) {
                guard !Task.isCancelled else { return false }
                await walk(to: LilBroPlanner.perch(on: rect))
                guard !Task.isCancelled else { return false }
                await punch(rect)
            }
            guard !Task.isCancelled else { return false }
            // The person went somewhere themselves: their choice stays.
            guard selection.changes == expected else { return personMoved(row) }
            stop.press()
            expected = selection.changes
            await settle()
        }
        guard selection.changes == expected else { return personMoved(row) }
        guard !Task.isCancelled else { return false }
        let landing = await landing(for: destination, expected: expected)
        guard !Task.isCancelled else { return false }
        guard selection.changes == expected else { return personMoved(row) }
        guard let block = landing else {
            // A row he could not show: back at home, nothing claimed.
            if row != nil { feet = map.homeStand }
            setPose(.idle)
            return row == nil
        }
        await walk(to: LilBroPlanner.perch(on: block))
        guard !Task.isCancelled else { return false }
        if let row {
            // Left its screen while he ran there, or went away and back:
            // nothing to outline.
            guard selection.changes == expected, leadIsActive(row), let now = map.visible(.row(row.id)) else {
                if selection.focusedRow == row.id { selection.focusedRow = nil }
                feet = map.homeStand
                setPose(.idle)
                return false
            }
            leadRow = row
            target = now
            feet = LilBroPlanner.perch(on: now)
        } else {
            // The person went elsewhere while he walked to the card: he
            // outlines nothing on their screen.
            guard selection.changes == expected else { return personMoved(row) }
            guard map.platforms.contains(block) else {
                feet = map.homeStand
                setPose(.idle)
                return true
            }
            target = block
        }
        holding = true
        setPose(.point)
        return true
    }

    /// Where he stands and what he outlines once the place is open: the row
    /// he was asked about, scrolled into view, or the screen's first block.
    // WHY: .project-docs/decisions/2026-11-24-lil-bro.md (REV 12)
    private func landing(for destination: LilBroDestination, expected: Int) async -> CGRect? {
        guard case .row(let row) = destination else { return firstPaneBlock() }
        // The person's tab wins: if they left the row's tab while it opened,
        // the lead ends here and their choice stays (builder review of #493,
        // ticket 630). Only the focus is set, never the tab again.
        guard row.isShown(on: selection.lilBroScreen) else { return nil }
        selection.focusedRow = row.id
        // The tab scrolls to it (0.3 s); the row counts once it stands still,
        // while it is still the focused row on its own tab. Never another
        // card instead.
        var last: CGRect?
        for _ in 0..<30 {
            guard selection.changes == expected, leadIsActive(row) else { return nil }
            let rect = map.visible(.row(row.id))
            if let rect, rect == last, map.platforms.contains(rect) { return rect }
            last = rect
            await sleep(0.05)
            if Task.isCancelled { return nil }
        }
        guard selection.changes == expected, leadIsActive(row) else { return nil }
        return map.visible(.row(row.id))
    }

    /// The person chose a place themselves while he led: their choice stays,
    /// nothing he led to is focused or outlined, and he does not say he
    /// opened it (builder tickets 631, 658, 663).
    private func personMoved(_ row: LilBroRow?) -> Bool {
        if let row, selection.focusedRow == row.id { selection.focusedRow = nil }
        leadRow = nil
        target = nil
        holding = false
        if mascotVisible {
            feet = map.homeStand
            setPose(.idle)
        }
        return false
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
        case .answer(let answer): text = answer.paragraphs.first ?? ""
        case .tooShort: text = LilBroCopy.tooShort
        case .offline: text = LilBroCopy.offline
        case .unavailable: text = LilBroCopy.unavailable
        case .limit: text = LilBroCopy.limit
        }
        announce(text)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// Lil Bro's fixed words, in one place for the view and the tests.
enum LilBroCopy {
    /// His greeting over the field, one per opening, in turn.
    static let greetings = [
        "Wassup bro? What we setting up?",
        "Yo! What you looking for?",
        "Sup bro, where we headed?",
        "Hey hey. What's the move?",
    ]
    static let offline = "I can’t reach whytap.ai — no internet, so answers aren’t available right now."
    static let unavailable = "whytap.ai can’t answer right now."
    static let limit = "I’ve answered as many questions as I can today. I’ll be back tomorrow."
    static let tooShort = "Tell me a bit more — a few words is enough."
    static let catchMe = "Catch me"
    static let placeholder = "Ask Lil Bro…"
}
