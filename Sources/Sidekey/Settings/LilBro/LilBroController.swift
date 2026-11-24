import AppKit
import SwiftUI

/// Whether the little guy runs around Settings. Off leaves only the "Lil Bro"
/// entry in the sidebar, which opens the same balloon.
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
    let brain: LilBroBrain
    private let reduceMotion: () -> Bool
    private let sleep: (TimeInterval) async -> Void
    private let now: () -> Date

    init(selection: SettingsWindowSelection,
         preferences: LilBroPreferences? = nil,
         brain: LilBroBrain? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1e9)) },
         now: @escaping () -> Date = Date.init) {
        self.selection = selection
        self.preferences = preferences ?? .shared
        self.brain = brain ?? LilBroLocalGuide()
        self.reduceMotion = reduceMotion
        self.sleep = sleep
        self.now = now
    }

    var mascotVisible: Bool { preferences.mascotVisible }
    var isOpen: Bool { bubble != .closed }
    var isBusy: Bool { busy }

    /// The pose to draw: a wave while the pointer is over him at rest.
    var shownPose: LilBroPose {
        hovering && pose == .idle && !busy && bubble == .closed ? .hover : pose
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

    /// A click on him: a surprised hop, then the balloon.
    func catchHim() {
        guard !busy, bubble == .closed else { return }
        cancelJob()
        setPose(.caught)
        job = Task { [weak self] in
            guard let self else { return }
            await sleep(reduceMotion() ? 0 : 0.44)
            guard !Task.isCancelled else { return }
            setPose(.idle)
            bubble = .full
        }
    }

    /// The sidebar entry: opens or closes the balloon.
    func toggleFromSidebar() {
        if bubble == .closed { bubble = .full } else { close() }
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
        job = Task { [weak self] in await self?.goHome() }
    }

    func clear() {
        turns = []
        menuOpen = false
        showEarlier = false
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
        turns.append(Turn(question: question))
        let index = turns.count - 1
        bubble = .thinking
        busy = true
        target = nil
        if mascotVisible { setPose(.think) }
        job = Task { [weak self] in
            guard let self else { return }
            let reply = await brain.reply(to: question)
            guard !Task.isCancelled, index < turns.count else { return }
            turns[index].reply = reply
            switch reply {
            case .answer(let answer):
                if let destination = answer.destination {
                    turns[index].opened = destination.title
                    await guide(to: destination)
                }
            case .offline, .limit, .unknown:
                if mascotVisible { setPose(.sad) }
            }
            guard !Task.isCancelled else { return }
            busy = false
            bubble = .full
            announce(turns[index])
        }
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
        guard mascotVisible, !reduceMotion() else {
            stops.forEach { $0.press() }
            await settle()
            if mascotVisible { arrive() }
            return
        }
        bubble = .tag("On my way…")
        for stop in stops {
            guard !Task.isCancelled else { return }
            if let rect = await visibleSpot(stop.spot) {
                await walk(to: LilBroPlanner.perch(on: rect))
                guard !Task.isCancelled else { return }
                await punch(rect)
            }
            stop.press()
            await settle()
        }
        guard !Task.isCancelled else { return }
        if let block = firstPaneBlock() {
            await walk(to: LilBroPlanner.perch(on: block))
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
            setPose(.land)
            await sleep(0.12)
        case .ladder(let from, let to):
            facingRight = true
            ladder = Ladder(x: from.x + 2, top: to.y - 5, bottom: from.y)
            setPose(.prop)
            await sleep(0.28)
            setPose(.climb)
            await animate(.climb(from: from, to: to, at: now()))
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
        if Task.isCancelled {
            feet = next.position(at: now())
        } else {
            feet = next.to
        }
        segment = nil
    }

    /// Two little punches at a row, then it is pressed.
    private func punch(_ rect: CGRect) async {
        face(rect.midX >= feet.x - 1 ? feet.x + 1 : feet.x - 1)
        setPose(.hit)
        flash = rect
        await sleep(0.43)
        flash = nil
        setPose(.idle)
    }

    func goHome() async {
        guard mascotVisible, let home = map.home else { return }
        busy = true
        defer { busy = false }
        let stand = abs(feet.y - (home.minY + 1)) < 3
            ? CGPoint(x: min(max(feet.x, home.minX + 16), home.maxX - 14), y: home.minY + 1)
            : map.homeStand
        await walk(to: stand)
        if !Task.isCancelled { facingRight = true }
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
                job = Task { [weak self] in
                    await self?.walk(to: CGPoint(x: x, y: home.minY + 1), stroll: true)
                    self?.job = nil
                }
            }
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
        case .limit: text = LilBroCopy.limit
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// Lil Bro's fixed words, in one place for the view and the tests.
enum LilBroCopy {
    static let greeting = "Hi, I’m Lil Bro. Ask me where anything is in Settings — I’ll run there and open it for you."
    static let localNote = "Answers come from this Mac for now: I find settings by name."
    static let unknown = "I only know Settings by name for now. Try one of these:"
    static let offline = "I can’t reach whytap.ai — no internet. Settings still work offline."
    static let limit = "I’ve answered as many questions as I can today. Settings still work."
    static let catchMe = "Catch me"
    static let placeholder = "Ask Lil Bro…"
}
