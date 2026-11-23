import AppKit
import SwiftUI

// The last three steps after the design pass's screens 05 to 09 (approved
// 2026-11-22; whytap.ai and Finish became one step in REV 61, Shortcuts was
// removed in REV 64): Try Drop, Toolbox and Enjoy Whytap, in the wire
// language of the steps before, with the person's own shortcut and tools. No island chip while Drop listens: the line under Try Drop's lede
// turns into soft waves that follow the voice and settles when it stops. No
// summary table at the end.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md

/// The springs of a finale figure, stepped per frame like the prototype.
final class OnboardingFinaleMotion {
    /// Offscreen renders and tests: every spring lands at once.
    static var settlesAtOnce = false

    private(set) var clock = 2.08
    private(set) var stage = OnboardingSpring(-0.35)
    private(set) var press = OnboardingSpring(0)
    private(set) var voice = OnboardingSpring(0)
    private(set) var fan = OnboardingSpring(0)
    private(set) var keys: [OnboardingSpring] = [OnboardingSpring(0), OnboardingSpring(0), OnboardingSpring(0)]
    private var last: TimeInterval?

    func still(_ reduceMotion: Bool) -> Bool { reduceMotion || Self.settlesAtOnce }

    func advance(to time: TimeInterval, reduceMotion: Bool, press goal: Double = 0, voice voiceGoal: Double = 0,
                 fan fanGoal: Double = 0, keys keyGoals: [Double] = [0, 0, 0]) {
        let still = still(reduceMotion)
        let dt = min(0.04, last.map { max(0, time - $0) } ?? 0.016)
        last = time
        if !still { clock += dt }
        if still { stage = OnboardingSpring(0) } else { stage.value += (0 - stage.value) * (1 - exp(-dt * 9)) }
        press.step(to: goal, stiffness: 210, damping: 13.5, dt: dt, still: still)
        voice.step(to: voiceGoal, stiffness: 120, damping: 14, dt: dt, still: still)
        fan.step(to: fanGoal, stiffness: 150, damping: 15, dt: dt, still: still)
        for i in keys.indices {
            keys[i].step(to: i < keyGoals.count ? keyGoals[i] : 0, stiffness: 210, damping: 13.5, dt: dt, still: still)
        }
    }

    var fade: Double { max(0.15, min(1, 1 + stage.value * 1.4)) }

    func sway(_ reduceMotion: Bool) -> (x: Double, y: Double) {
        still(reduceMotion) ? (0, 0) : (cos(clock * 0.44) * 0.05, sin(clock * 0.56) * 0.10)
    }
}

// MARK: - Try Drop

/// Where Try Drop stands: waiting for a take, recording, the text arrived,
/// or a calm line about a take that brought nothing.
enum OnboardingTryState: Equatable {
    case waiting
    case recording
    case done
    case failed(String)

    var tone: OnboardingWireTone {
        switch self {
        case .waiting: return .rest
        case .recording: return .active
        case .done: return .done
        case .failed: return .warn
        }
    }
}

/// Try Drop: the person's shortcut as keys, a real text field Drop types
/// into, and the line that becomes the voice while Drop listens.
struct OnboardingTryDropStage: View {
    @ObservedObject var model: OnboardingJourneyModel
    @ObservedObject var voice: OnboardingVoiceSignal
    let shortcut: HotkeyShortcut
    let gesture: HotkeyGesture
    /// Offscreen renders show a state without a take.
    var shownState: OnboardingTryState?
    var shownLevel: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OnboardingFinaleMotion()
    /// The preview's pretend take, typed into the field as Drop would.
    @State private var take: String?

    init(model: OnboardingJourneyModel, shortcut: HotkeyShortcut, gesture: HotkeyGesture,
         shownState: OnboardingTryState? = nil, shownLevel: Double? = nil, shownText: String? = nil) {
        self.model = model
        voice = model.voice
        self.shortcut = shortcut
        self.gesture = gesture
        self.shownState = shownState
        self.shownLevel = shownLevel
        _take = State(initialValue: shownText)
    }

    private var state: OnboardingTryState {
        if let shownState { return shownState }
        switch model.outcome(.tryDrop) {
        case .done: return .done
        case .failed(let reason): return voice.recording ? .recording : .failed(reason)
        default: return voice.recording ? .recording : .waiting
        }
    }

    private var holds: Bool { gesture == .hold }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingWireTitle(title: "Try Drop.", lede: "Your own shortcut, in a real text field.")
            figure.frame(height: 84)
            field
                .padding(.horizontal, 44)
            // The field's header is the one place that says which key to
            // hold; no line under the field. Continue is there from the
            // start and works once a take arrived; Skip leaves any time,
            // a take running included.
            // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
            HStack(spacing: 14) {
                let done = state == .done
                OnboardingWirePill("Continue", tone: done ? .done : .rest, disc: done ? .check : .arrow,
                                   isDefault: done, interactive: done, action: model.next)
                    .opacity(done ? 1 : 0.4)
                    .accessibilityHint(done ? "" : "Available after your first take")
                if !done {
                    OnboardingWireLink(title: "Skip", arrow: "arrow.right", action: model.next)
                }
            }
            .frame(height: 46)
            .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        // The standalone preview has no Drop: its stand-in listens for the
        // person's Drop shortcut in the window while the step is shown.
        .onAppear {
            guard shownState == nil else { return }
            model.dropStandIn?.attach(shortcut: shortcut, gesture: gesture, voice: voice) { text in take = text }
        }
        .onDisappear { model.dropStandIn?.detach() }
    }

    private var figure: some View {
        let state = self.state
        let voice = self.voice
        let level = shownLevel
        let shortcut = self.shortcut
        return TimelineView(.animation) { timeline in
            Canvas { context, size in
                let recording = state == .recording
                let heard = level ?? voice.level
                motion.advance(to: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion,
                               press: recording ? 1 : 0, voice: recording ? min(1.1, 0.28 + heard * 1.5) : 0)
                let still = motion.still(reduceMotion)
                let energy = still ? 0.94 : min(1.08, 0.58 + 0.24 * abs(sin(motion.clock * 5.8))
                                              + 0.18 * abs(cos(motion.clock * 9.3 + 0.8)) + heard * 0.3)
                OnboardingVoiceLine.draw(in: &context, from: 64, to: size.width - 64, y: 18,
                                         amplitude: motion.voice.value, energy: energy,
                                         phase: still ? 2.08 : motion.clock, tone: state.tone)
                let sway = motion.sway(reduceMotion)
                let bob = still ? 0 : sin(motion.clock * 0.78) * 1.1
                let key = OnboardingFinaleFigures.dropKeys[OnboardingFinaleFigures.legend(for: shortcut)]
                    ?? OnboardingFinaleFigures.dropKeys[.none]!
                key.draw(
                    in: &context, center: CGPoint(x: size.width / 2, y: 57 + bob), radius: 26,
                    angles: (ax: -0.50 + sway.x, ay: -0.52 + sway.y, az: 0.03), worldZ: motion.stage.value,
                    press: max(-0.12, min(1.25, motion.press.value)), fade: motion.fade, tint: state.tone.tint,
                    strength: state == .waiting ? 0.62 : state == .recording ? 0.94 : 0.9, clock: motion.clock)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var status: (String, Color) {
        switch state {
        case .waiting, .failed: return ("", OnboardingTheme.faint)
        case .recording: return ("LISTENING", OnboardingTheme.muted)
        case .done:
            return (model.tryDropSeconds.map { String(format: "%.1f S", $0) } ?? "", OnboardingWireframeInk.greenColor)
        }
    }

    private var field: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(holds ? "Hold" : "Press")
                OnboardingKeycaps(contents: shortcut.contents, held: state == .recording).fixedSize()
                Text("and speak")
                Spacer(minLength: 8)
                Text(status.0)
                    .font(OnboardingTheme.mono(10, weight: .medium))
                    .tracking(0.8)
                    .foregroundColor(status.1)
            }
            .font(OnboardingTheme.sans(13))
            .foregroundColor(OnboardingTheme.muted)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .overlay(Rectangle().fill(OnboardingTheme.border).frame(height: 0.5), alignment: .bottom)
            OnboardingTryField(placeholder: Self.emptyText(state).text,
                               placeholderColor: Self.emptyText(state).failed ? NSColor(OnboardingWireframeInk.amberColor) : nil,
                               take: take, onDictated: model.noteDictated)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54, alignment: .topLeading)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(red: 0.106, green: 0.106, blue: 0.122)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(state == .waiting ? OnboardingTheme.borderStrong : state.tone.border, lineWidth: 1))
    }

    /// The field's empty text: where the words go, not which key to hold.
    static let placeholder = "Your text will appear here"

    /// What the empty field says: the placeholder, or a take that brought
    /// nothing here ("No speech heard - try again."), inside the field
    /// instead of a line under it.
    static func emptyText(_ state: OnboardingTryState) -> (text: String, failed: Bool) {
        if case .failed(let reason) = state { return (reason, true) }
        return (placeholder, false)
    }
}

// MARK: - Toolbox

/// Toolbox: every tool of the Toolbox catalog on a ring, a circle tilted
/// toward the person (the near tiles a little larger) that turns slowly like
/// a carousel, and a small card in its middle. Pointing at a tile (or the
/// keyboard focus) stops the turn, lights the tile and names it on the card
/// with its short description; with none, the card says what Toolbox is and
/// the ring turns on.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
struct OnboardingToolboxStage: View {
    @ObservedObject var model: OnboardingJourneyModel
    /// Offscreen renders show the card on a tool.
    var shownTool: HoverTool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OnboardingFinaleMotion()
    @State private var carousel = OnboardingCarousel()
    @State private var shown = false
    @State private var hovered: HoverTool?
    @FocusState private var focused: HoverTool?

    init(model: OnboardingJourneyModel, shownTool: HoverTool? = nil) {
        self.model = model
        self.shownTool = shownTool
    }

    /// The whole Toolbox catalog, as Settings → Toolbox lists it: every tool
    /// but Settings (always on the island), tools not out yet included.
    static var tools: [HoverTool] { HoverTool.allCases.filter { $0 != .settings } }

    /// What the card says: the tool's title and short description, or the
    /// line about Toolbox.
    static func card(for tool: HoverTool?) -> (title: String, text: String) {
        guard let tool else {
            return ("Your quick tools", "Point at one to see what it does.")
        }
        let info = HoverToolRegistry.info(for: tool)
        if tool.isComingSoon { return ("\(info.title) · \(CalendarAvailability.badge)", CalendarAvailability.message) }
        return (info.title, info.description)
    }

    static let tile: CGFloat = 38
    /// The card in the middle: small, so the tiles carry the ring.
    static let cardSize = CGSize(width: 176, height: 76)

    private var selected: HoverTool? { hovered ?? focused ?? shownTool }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingWireTitle(title: "Tools above the island.",
                                lede: "Hover the island at the top of the screen. Pick yours in Settings → Toolbox.")
            ring
                .frame(maxHeight: .infinity)
            OnboardingWirePill("Continue", isDefault: true, action: model.next)
                .padding(.top, 6)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .onAppear { shown = true }
    }

    /// Radii of the ring in this area: as wide as the window allows and as
    /// tall as the area, so the circle is seen tilted.
    static func radii(_ size: CGSize) -> (x: CGFloat, y: CGFloat) {
        (max(60, size.width / 2 - tile / 2 - 10), max(40, size.height / 2 - tile / 2 - 2))
    }

    /// The tilt: tiles on the near (lower) half of the ring a little larger.
    static func tileScale(_ spot: CGPoint, in size: CGSize) -> CGFloat {
        0.9 + 0.1 * (spot.y - size.height / 2) / max(1, radii(size).y)
    }

    /// The tiles' places at equal steps along the ring (equal angles would
    /// crowd its narrow ends), the first at the top when `turn` is 0; `turn`
    /// (0 to 1, one full round) moves every tile along the ring.
    static func spots(_ count: Int, in size: CGSize, spread: CGFloat = 1, turn: Double = 0) -> [CGPoint] {
        guard count > 0 else { return [] }
        let r = radii(size)
        let samples = 720
        let points = (0...samples).map { i -> CGPoint in
            let angle = -Double.pi / 2 + Double(i) / Double(samples) * 2 * Double.pi
            return CGPoint(x: size.width / 2 + CGFloat(cos(angle)) * r.x * spread,
                           y: size.height / 2 + CGFloat(sin(angle)) * r.y * spread)
        }
        var lengths: [CGFloat] = [0]
        for i in 1...samples {
            lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        let total = lengths[samples]
        let offset = turn - floor(turn)
        return (0..<count).map { index in
            var fraction = Double(index) / Double(count) + offset
            fraction -= floor(fraction)
            let goal = total * CGFloat(fraction)
            var low = 0, high = samples
            while high - low > 1 {
                let mid = (low + high) / 2
                if lengths[mid] < goal { low = mid } else { high = mid }
            }
            let part = (goal - lengths[low]) / max(0.0001, lengths[high] - lengths[low])
            return CGPoint(x: points[low].x + (points[high].x - points[low].x) * part,
                           y: points[low].y + (points[high].y - points[low].y) * part)
        }
    }

    private var ring: some View {
        let tools = Self.tools
        let selected = self.selected
        // A pointed (or focused) tile stops the carousel; it goes on when the
        // pointer leaves. Offscreen renders and Reduce Motion stand still.
        let paused = hovered != nil || focused != nil || shownTool != nil
        return GeometryReader { proxy in
            let size = proxy.size
            let card = Self.cardSize
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let _ = motion.advance(to: time, reduceMotion: reduceMotion, fan: shown || shownTool != nil ? 1 : 0)
                let turn = carousel.advance(to: time, paused: paused, still: motion.still(reduceMotion))
                let spread = 0.55 + 0.45 * max(0, min(1.04, motion.fan.value))
                let fade = max(0, min(1, motion.fan.value))
                let spots = Self.spots(tools.count, in: size, spread: spread, turn: turn)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let r = Self.radii(size)
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let oval = CGRect(x: center.x - r.x * spread, y: center.y - r.y * spread,
                                          width: r.x * spread * 2, height: r.y * spread * 2)
                        context.stroke(Path(ellipseIn: oval),
                                       with: .color(OnboardingWireframeInk.wireColor.opacity(0.16 * fade)), lineWidth: 0.8)
                        guard let selected, let index = tools.firstIndex(of: selected) else { return }
                        let tip = spots[index]
                        // The spoke leaves the card's edge, not its middle.
                        let dx = tip.x - center.x, dy = tip.y - center.y
                        let along = 0.5 / max(abs(dx) / card.width, abs(dy) / card.height, 0.001)
                        let from = CGPoint(x: center.x + dx * along, y: center.y + dy * along)
                        let length = max(1, hypot(dx, dy))
                        let to = CGPoint(x: tip.x - dx / length * (Self.tile / 2 + 3),
                                         y: tip.y - dy / length * (Self.tile / 2 + 3))
                        context.stroke(Path { $0.move(to: from); $0.addLine(to: to) },
                                       with: .color(OnboardingWireframeInk.roseColor.opacity(0.55 * fade)), lineWidth: 1)
                        context.fill(Path(ellipseIn: CGRect(x: from.x - 1.8, y: from.y - 1.8, width: 3.6, height: 3.6)),
                                     with: .color(OnboardingWireframeInk.roseColor.opacity(0.8 * fade)))
                    }
                    .allowsHitTesting(false)
                    self.card(selected)
                        .frame(width: card.width, height: card.height)
                        .opacity(fade)
                        .position(x: size.width / 2, y: size.height / 2)
                    ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                        let scale = Self.tileScale(spots[index], in: size)
                        tile(tool, lit: tool == selected)
                            .scaleEffect(scale)
                            .opacity(fade * (0.86 + 1.4 * (scale - 0.9)))
                            .position(spots[index])
                            .zIndex(tool == selected ? 1 : 0)
                    }
                }
            }
        }
    }

    private func card(_ tool: HoverTool?) -> some View {
        let text = Self.card(for: tool)
        return VStack(spacing: 3) {
            Text("TOOLBOX")
                .font(OnboardingTheme.mono(9, weight: .medium))
                .tracking(1.4)
                .foregroundColor(tool == nil ? OnboardingTheme.muted : OnboardingWireframeInk.roseColor)
            Text(text.title)
                .font(OnboardingTheme.sans(13.5, weight: .semibold))
                .foregroundColor(OnboardingTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(text.text)
                .font(OnboardingTheme.sans(11))
                .foregroundColor(OnboardingTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(red: 0.106, green: 0.106, blue: 0.122)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(tool == nil ? Color.white.opacity(0.10) : OnboardingWireframeInk.roseColor.opacity(0.32), lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func tile(_ tool: HoverTool, lit: Bool) -> some View {
        let info = HoverToolRegistry.info(for: tool)
        let soon = tool.isComingSoon
        return Button {} label: {
            Image(systemName: info.sfSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(lit ? OnboardingTheme.ink : OnboardingTheme.ink2.opacity(soon ? 0.5 : 0.9))
                .frame(width: Self.tile, height: Self.tile)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(lit ? Color(red: 0.19, green: 0.15, blue: 0.17) : Color(red: 0.13, green: 0.13, blue: 0.15)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(lit ? OnboardingWireframeInk.roseColor.opacity(0.8) : Color.white.opacity(soon ? 0.07 : 0.12),
                                  lineWidth: lit ? 1.3 : 1))
                .scaleEffect(lit ? 1.1 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7), value: lit)
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focused, equals: tool)
        .onHover { inside in
            if inside { hovered = tool } else if hovered == tool { hovered = nil }
        }
        .accessibilityLabel(info.title)
        .accessibilityHint(soon ? CalendarAvailability.message : info.description)
    }
}

/// The Toolbox ring's slow turn, stepped per display frame: one round in
/// `period` seconds, held while a tile is pointed at and still under Reduce
/// Motion or in offscreen renders.
final class OnboardingCarousel {
    var period: TimeInterval = 70
    private(set) var turn = 0.0
    private var last: TimeInterval?

    func advance(to time: TimeInterval, paused: Bool, still: Bool) -> Double {
        let dt = min(0.05, last.map { max(0, time - $0) } ?? 0)
        last = time
        if !paused, !still { turn = (turn + dt / period).truncatingRemainder(dividingBy: 1) }
        return turn
    }
}

// MARK: - Finish

/// The last step: "Enjoy Whytap.", a list of questions worth asking the
/// agent on whytap.ai whose rows give way to other questions one at a time,
/// the one Ask line, and Finish. It took the place of a separate whytap.ai
/// page; the list took the place of a constellation of figures.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
struct OnboardingFinishStage: View {
    @ObservedObject var model: OnboardingJourneyModel
    /// Offscreen renders show the list without its drift.
    var still = false
    /// Offscreen renders: a point of the drift and a row under the pointer.
    var shownOffset: CGFloat?
    var shownPointed: Int?
    @Environment(\.openURL) private var openURL

    static let site = URL(string: "https://whytap.ai")!

    var body: some View {
        VStack(spacing: 0) {
            OnboardingWireTitle(title: "Enjoy Whytap.", lede: "We hope you’ll love having it on your Mac.")
            // The list's own fades stand in for the gaps above and below it.
            OnboardingQuestionList(still: still, shownOffset: shownOffset, shownPointed: shownPointed) {
                openURL(OnboardingQuestionList.link(for: $0))
            }
            OnboardingAskLine { openURL(Self.site) }
                .padding(.top, 4)
            OnboardingWirePill("Finish", disc: .finish, isDefault: true, action: model.finish)
                .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Questions a new person can ask the agent on whytap.ai: a long loop of
/// rows (icon, question, ↗) that drifts slowly from the bottom up, four rows
/// in view, new ones rising in at the bottom and the top one leaving, the
/// edges fading. The pointer on the list stops the drift and lights the row
/// under it; a click asks that question on whytap.ai (`?q=` asks it as the
/// page opens). Reduce Motion moves a whole row at a time, without motion.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
struct OnboardingQuestionList: View {
    /// Real questions the Ask agent answers (its eval pool,
    /// whytap-landing `ask/eval/pool.json`), short enough for one line.
    static let questions = [
        "Which models should I pick in API & Models to start?",
        "Can I tap to start dictation and tap again to stop?",
        "Can Whytap turn Russian speech into English text?",
        "Can I teach Whytap custom words and names?",
        "How do I let Claude Code use my Case keys safely?",
        "Can Whytap show live translated subtitles on calls?",
        "How do I split my meeting transcript by speaker?",
        "How do I pick which microphone Whytap uses?",
        "Can Whytap dictate without sending my voice online?",
        "What do I set up for the Right Command agent?",
        "How do I add Whytap Case as an MCP server in Codex?",
        "Where are my meeting notes kept?",
        "How do I move Whytap to a new MacBook?",
        "How do I share meeting notes with a colleague?",
        "How do I switch dictation from Fast to Smart?",
        "Can Whytap make my screen brighter than max?",
        "Where do I see what I spent on APIs this month?",
        "Can Whytap cut filler words from my dictation?",
        "Can I run Whytap fully local with Ollama?",
        "How do I quit Whytap completely?",
    ]

    /// whytap.ai with the question in the link; the page asks it on load.
    static func link(for question: String) -> URL {
        var parts = URLComponents(string: "https://whytap.ai/")!
        parts.queryItems = [URLQueryItem(name: "q", value: question)]
        return parts.url!
    }

    static let rows = 4
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 6
    static let width: CGFloat = 404
    /// One row and its gap: the drift's step.
    static var step: CGFloat { rowHeight + rowSpacing }
    /// Four rows in full.
    static var rowsHeight: CGFloat { CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing }
    /// The fade at the top and bottom edges: a margin of its own, so the four
    /// rows at rest are never dimmed; only rows coming and going fade.
    static let fade: CGFloat = 14
    /// The window: the four rows and a fade above and below them.
    static var height: CGFloat { rowsHeight + 2 * fade }
    /// Slow enough to read a row as it passes: a row every 4.5 s.
    static let speed: CGFloat = 8

    /// The questions laid out once round and then the first rows again, so
    /// the loop's end meets its start without a seam.
    static var tape: [Int] { Array(questions.indices) + Array(0...rows) }
    /// One whole round of the loop, in points.
    static var round: CGFloat { CGFloat(questions.count) * step }

    /// The window's position on the loop for a drift `travel` points long:
    /// smooth, or whole rows under Reduce Motion.
    static func offset(_ travel: CGFloat, wholeRows: Bool) -> CGFloat {
        let along = travel.truncatingRemainder(dividingBy: round)
        return wholeRows ? (along / step).rounded(.down) * step : along
    }

    /// The questions in the window at `offset`: any part of a row (`inFull`
    /// false), or only rows wholly clear of the fades (`inFull` true).
    static func visible(at offset: CGFloat, inFull: Bool = false) -> [Int] {
        let tape = tape
        let first = max(0, Int((offset / step).rounded(.down)) - 1)
        return (first..<tape.count).filter { index in
            let top = fade + CGFloat(index) * step - offset
            return inFull ? top >= fade - 0.001 && top + rowHeight <= height - fade + 0.001
                          : top < height && top + rowHeight > 0
        }.map { tape[$0] }
    }

    var still = false
    /// Offscreen renders: a point of the drift and a row (tape slot) under
    /// the pointer.
    var shownOffset: CGFloat?
    var shownPointed: Int?
    let ask: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = OnboardingQuestionDrift()
    @State private var hovered = false
    @State private var pointed: Int?
    @FocusState private var focused: Int?

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.5 : nil, paused: still)) { context in
            let travel = drift.advance(to: context.date.timeIntervalSinceReferenceDate,
                                       paused: hovered || focused != nil, still: still)
            let offset = shownOffset ?? Self.offset(travel, wholeRows: reduceMotion)
            VStack(spacing: Self.rowSpacing) {
                ForEach(Array(Self.tape.enumerated()), id: \.offset) { slot, index in
                    row(index, slot: slot)
                }
            }
            .frame(width: Self.width, alignment: .top)
            .offset(y: Self.fade - offset)
            .frame(width: Self.width, height: Self.height, alignment: .top)
            .clipped()
            .mask(Self.edges)
        }
        .frame(width: Self.width, height: Self.height)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Questions to ask on whytap.ai")
    }

    /// The top and bottom edges fade, so rows rise in and leave softly.
    static var edges: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fade)
        }
    }

    private func row(_ index: Int, slot: Int) -> some View {
        let question = Self.questions[index]
        let lit = (pointed ?? shownPointed) == slot
        return Button { ask(question) } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(OnboardingWireframeInk.roseColor.opacity(lit ? 1 : 0.9))
                Text(question)
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.ink.opacity(lit ? 1 : 0.92))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(lit ? OnboardingTheme.ink : OnboardingTheme.muted)
            }
            .padding(.horizontal, 14)
            .frame(width: Self.width, height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(lit ? Color(red: 0.17, green: 0.17, blue: 0.19) : Color(red: 0.12, green: 0.12, blue: 0.135)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused == slot ? OnboardingTheme.accent
                              : lit ? OnboardingWireframeInk.roseColor.opacity(0.45) : Color.white.opacity(0.10),
                              lineWidth: focused == slot ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .animation(.easeOut(duration: 0.12), value: lit)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focused, equals: slot)
        .onHover { inside in
            if inside {
                pointed = slot
                NSCursor.pointingHand.set()
            } else if pointed == slot {
                pointed = nil
                NSCursor.arrow.set()
            }
        }
        .accessibilityLabel("Ask on whytap.ai: \(question)")
    }
}

/// The question list's drift, stepped per display frame: `speed` points a
/// second, held while the pointer or focus is on the list and still in
/// offscreen renders.
final class OnboardingQuestionDrift {
    var speed: CGFloat = OnboardingQuestionList.speed
    private(set) var travel: CGFloat = 0
    private var last: TimeInterval?

    func advance(to time: TimeInterval, paused: Bool, still: Bool) -> CGFloat {
        // Reduce Motion ticks twice a second; a longer gap (a hidden window)
        // does not jump the list ahead.
        let dt = min(0.6, last.map { max(0, time - $0) } ?? 0)
        last = time
        if !paused, !still { travel += CGFloat(dt) * speed }
        return travel
    }
}

/// The one line about questions: a quiet Ask capsule that opens whytap.ai,
/// where the agent answers with steps for the person's setup.
struct OnboardingAskLine: View {
    let action: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                (Text("Questions? Ask on ") + Text(verbatim: "whytap.ai").foregroundColor(OnboardingTheme.ink))
                    .font(OnboardingTheme.sans(13))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(hovered ? 1 : 0.9)))
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(width: 264, height: 36)
            .background(Capsule(style: .continuous).fill(Color.black.opacity(hovered ? 0.5 : 0.35)))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(hovered ? OnboardingWireframeInk.roseColor.opacity(0.4) : Color.white.opacity(0.09), lineWidth: 1))
            .overlay(Capsule(style: .continuous).strokeBorder(focused ? OnboardingTheme.accent : .clear, lineWidth: 2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hovered = $0 }
        .accessibilityLabel("Ask on whytap.ai")
        .accessibilityHint("Opens whytap.ai, where the agent answers questions about Whytap")
    }
}
