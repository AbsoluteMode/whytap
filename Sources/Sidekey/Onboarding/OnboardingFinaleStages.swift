import AppKit
import SwiftUI

// The last four steps after the design pass's screens 05 to 09 (approved
// 2026-11-22; whytap.ai and Finish became one step in REV 61): Try Drop,
// Shortcuts, Toolbox and Enjoy Whytap, in the
// wire language of the steps before, with the person's own shortcuts and
// tools. No island chip while Drop listens: the line under Try Drop's lede
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

// MARK: - Shortcuts

/// One shortcut row: what it opens and the person's own keys.
struct OnboardingShortcutRow: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let shortcut: HotkeyShortcut
    var note: String?

    /// Drop, the Agent and the tools with a shortcut, up to six, from the
    /// person's own configuration.
    static func rows(_ configuration: HotkeyConfiguration, agentEnabled: Bool) -> [OnboardingShortcutRow] {
        var rows = [OnboardingShortcutRow(id: "drop", title: "Drop", symbol: "mic", shortcut: configuration.dropVoiceShortcut),
                    OnboardingShortcutRow(id: "agent", title: "Agent", symbol: "sparkle", shortcut: configuration.agentTextShortcut,
                                          note: agentEnabled ? nil : "Off")]
        let order: [HoverTool] = [.screenshot, .translate, .clipboard, .notes, .caseVault, .tasks, .subtitles, .meetingRecord,
                                  .notifs, .monitor]
        for tool in order where rows.count < 6 {
            guard let shortcut = configuration.toolShortcuts[tool] else { continue }
            let info = HoverToolRegistry.info(for: tool)
            rows.append(OnboardingShortcutRow(id: tool.rawValue, title: info.title, symbol: info.sfSymbol, shortcut: shortcut))
        }
        return rows
    }

    /// Which of ⌥, ⇧ and ⌘ the shortcut holds (the keys over the list).
    var modifiers: [Double] {
        let text = shortcut.contents.map { content -> String in
            switch content {
            case .text(let value): return value
            case .symbol(let name, _): return name
            case .prefixedGlyph(let prefix, let glyph, _): return prefix + glyph
            }
        }.joined() + shortcut.title
        func has(_ marks: [String]) -> Double { marks.contains { text.localizedCaseInsensitiveContains($0) } ? 1 : 0 }
        return [has(["⌥", "option"]), has(["⇧", "shift"]), has(["⌘", "command"])]
    }
}

/// Shortcuts: three wire keys over the person's shortcuts in two columns;
/// the keys a row uses go down while the pointer is on it.
struct OnboardingShortcutsStage: View {
    @ObservedObject var model: OnboardingJourneyModel
    let configuration: HotkeyConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OnboardingFinaleMotion()
    @State private var hovered: String?

    private var rows: [OnboardingShortcutRow] {
        OnboardingShortcutRow.rows(configuration, agentEnabled: model.agentEnabled())
    }

    var body: some View {
        let rows = self.rows
        let goals = rows.first { $0.id == hovered }?.modifiers ?? [0, 0, 0]
        VStack(spacing: 0) {
            OnboardingWireTitle(title: "Every tool has a shortcut.",
                                lede: "These are yours now. Change them in Settings → Hotkeys.")
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    motion.advance(to: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion, keys: goals)
                    let sway = motion.sway(reduceMotion)
                    let still = motion.still(reduceMotion)
                    let center = CGPoint(x: size.width / 2, y: size.height / 2 + (still ? 0 : sin(motion.clock * 0.72) * 1.3))
                    let angles = (ax: -0.52 + sway.x, ay: -0.34 + sway.y, az: 0.02)
                    for (index, key) in OnboardingFinaleFigures.cluster.enumerated() {
                        let press = motion.keys[index].value
                        key.draw(in: &context, center: center, radius: 24, angles: angles, worldZ: motion.stage.value,
                                 press: press, fade: motion.fade * (index == 2 ? 1 : 0.94), tint: OnboardingWireframeInk.rose,
                                 strength: (index == 2 ? 0.68 : 0.58) + 0.36 * press, clock: motion.clock)
                    }
                }
            }
            .frame(height: 64)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 4)
            OnboardingWirePill("Continue", isDefault: true, action: model.next)
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func rowView(_ row: OnboardingShortcutRow) -> some View {
        let lit = hovered == row.id
        return HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(OnboardingTheme.ink2)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.35)))
            Text(row.title)
                .font(OnboardingTheme.sans(14, weight: .semibold))
                .foregroundColor(row.note == nil ? OnboardingTheme.ink : OnboardingTheme.muted)
                .lineLimit(1)
            if let note = row.note {
                Text(note.uppercased())
                    .font(OnboardingTheme.mono(9, weight: .semibold))
                    .foregroundColor(OnboardingTheme.faint)
            }
            Spacer(minLength: 4)
            OnboardingKeycaps(contents: row.shortcut.contents, held: lit).fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(lit ? 0.07 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(lit ? 0.16 : 0.08), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { inside in
            if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title): \(row.shortcut.title)\(row.note.map { ", \($0)" } ?? "")")
    }
}

// MARK: - Toolbox

/// Toolbox: every tool of the Toolbox catalog on a ring, a circle tilted
/// toward the person (the near tiles a little larger), and a card in its
/// middle. The card names Toolbox and the tool under the pointer (or keyboard
/// focus) with its short description; with none, a line about Toolbox.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
struct OnboardingToolboxStage: View {
    @ObservedObject var model: OnboardingJourneyModel
    /// Offscreen renders show the card on a tool.
    var shownTool: HoverTool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OnboardingFinaleMotion()
    @State private var shown = false
    @State private var hovered: HoverTool?
    @State private var picked: HoverTool?
    @FocusState private var focused: HoverTool?

    init(model: OnboardingJourneyModel, shownTool: HoverTool? = nil) {
        self.model = model
        self.shownTool = shownTool
    }

    /// The whole Toolbox catalog, as Settings → Toolbox lists it: every tool
    /// but Settings (always on the island), tools not out yet included.
    static var tools: [HoverTool] { HoverTool.allCases.filter { $0 != .settings } }

    /// What the card says: the tool's title and short description, or `nil`
    /// for the line about Toolbox.
    static func card(for tool: HoverTool?) -> (title: String, text: String) {
        guard let tool else {
            return ("Your quick tools", "Point at one to see what it does.")
        }
        let info = HoverToolRegistry.info(for: tool)
        if tool.isComingSoon { return ("\(info.title) · \(CalendarAvailability.badge)", CalendarAvailability.message) }
        return (info.title, info.description)
    }

    static let tile: CGFloat = 30

    private var selected: HoverTool? { hovered ?? focused ?? picked ?? shownTool }

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

    /// Radii of the ring in this area: the window is wide and low, so the
    /// circle is seen tilted, about twice as wide as it is tall.
    private static func radii(_ size: CGSize) -> (x: CGFloat, y: CGFloat) {
        let y = max(40, size.height / 2 - tile * 0.55 - 1)
        let x = min(size.width / 2 - tile / 2 - 22, y * 2.2)
        return (x, y)
    }

    /// The tilt: tiles on the near (lower) half of the ring a little larger.
    static func tileScale(_ spot: CGPoint, in size: CGSize) -> CGFloat {
        0.9 + 0.1 * (spot.y - size.height / 2) / max(1, radii(size).y)
    }

    /// The tiles' places, the first at the top, at equal steps along the
    /// ring (equal angles would crowd its narrow ends).
    static func spots(_ count: Int, in size: CGSize, spread: CGFloat = 1) -> [CGPoint] {
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
        var spots: [CGPoint] = []
        var j = 0
        for index in 0..<count {
            let goal = total * CGFloat(index) / CGFloat(count)
            while j < samples, lengths[j + 1] < goal { j += 1 }
            let part = (goal - lengths[j]) / max(0.0001, lengths[j + 1] - lengths[j])
            spots.append(CGPoint(x: points[j].x + (points[j + 1].x - points[j].x) * part,
                                 y: points[j].y + (points[j + 1].y - points[j].y) * part))
        }
        return spots
    }

    private var ring: some View {
        let tools = Self.tools
        let selected = self.selected
        return GeometryReader { proxy in
            let size = proxy.size
            let r = Self.radii(size)
            // The card fills the middle and stays clear of the tiles.
            let card = CGSize(width: max(150, r.x * 1.25), height: max(64, r.y * 2 - Self.tile * 2.2))
            TimelineView(.animation) { timeline in
                let _ = motion.advance(to: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion,
                                       fan: shown || shownTool != nil ? 1 : 0)
                let spread = 0.55 + 0.45 * max(0, min(1.04, motion.fan.value))
                let fade = max(0, min(1, motion.fan.value))
                let spots = Self.spots(tools.count, in: size, spread: spread)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
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
                        let to = CGPoint(x: tip.x - dx / hypot(dx, dy) * (Self.tile / 2 + 3),
                                         y: tip.y - dy / hypot(dx, dy) * (Self.tile / 2 + 3))
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
        return VStack(spacing: 5) {
            Text("TOOLBOX")
                .font(OnboardingTheme.mono(10, weight: .medium))
                .tracking(1.6)
                .foregroundColor(tool == nil ? OnboardingTheme.muted : OnboardingWireframeInk.roseColor)
            Text(text.title)
                .font(OnboardingTheme.sans(15, weight: .semibold))
                .foregroundColor(OnboardingTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(text.text)
                .font(OnboardingTheme.sans(12))
                .foregroundColor(OnboardingTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(red: 0.106, green: 0.106, blue: 0.122)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(tool == nil ? Color.white.opacity(0.10) : OnboardingWireframeInk.roseColor.opacity(0.32), lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func tile(_ tool: HoverTool, lit: Bool) -> some View {
        let info = HoverToolRegistry.info(for: tool)
        let soon = tool.isComingSoon
        return Button { picked = tool } label: {
            Image(systemName: info.sfSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(lit ? OnboardingTheme.ink : OnboardingTheme.ink2.opacity(soon ? 0.5 : 0.9))
                .frame(width: Self.tile, height: Self.tile)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(lit ? Color(red: 0.19, green: 0.15, blue: 0.17) : Color(red: 0.13, green: 0.13, blue: 0.15)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(lit ? OnboardingWireframeInk.roseColor.opacity(0.8) : Color.white.opacity(soon ? 0.07 : 0.12),
                                  lineWidth: lit ? 1.3 : 1))
                .scaleEffect(lit ? 1.14 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7), value: lit)
                .contentShape(RoundedRectangle(cornerRadius: 10))
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

// MARK: - Finish

/// The last step: "Enjoy Whytap.", the figures of the steps before turning
/// slowly on one ring, one line that sends questions to the agent on
/// whytap.ai, and Finish. It took the place of a separate whytap.ai page.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
struct OnboardingFinishStage: View {
    @ObservedObject var model: OnboardingJourneyModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var motion = OnboardingFinaleMotion()

    static let site = URL(string: "https://whytap.ai")!

    var body: some View {
        VStack(spacing: 0) {
            OnboardingWireTitle(title: "Enjoy Whytap.", lede: "We hope you’ll love having it on your Mac.")
            constellation.frame(height: 136).padding(.top, 4)
            OnboardingAskLine { openURL(Self.site) }
                .padding(.top, 6)
            OnboardingWirePill("Finish", disc: .finish, isDefault: true, action: model.finish)
                .padding(.top, 18)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var constellation: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                motion.advance(to: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
                let still = motion.still(reduceMotion)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let rx = 128.0, ry = 27.0
                context.stroke(Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)),
                               with: .color(OnboardingWireframeInk.wireColor.opacity(0.15 * motion.fade)), lineWidth: 0.9)
                let turn = still ? 0.36 : motion.clock * 0.32
                let sway = motion.sway(reduceMotion)
                let items = (0..<4).map { index in (index, turn + Double(index) / 4 * 2 * .pi) }.sorted { sin($0.1) < sin($1.1) }
                for (index, angle) in items {
                    let depth = sin(angle)
                    let point = CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * depth)
                    let radius = 21.5 + depth * 3.8
                    let spin = still ? -0.38 : -0.35 + sin(motion.clock * 0.6 + Double(index)) * 0.25
                    let angles = (ax: -0.30 + sway.x, ay: spin + sway.y, az: 0.05)
                    let tint = index % 2 == 0 ? OnboardingWireframeInk.green : OnboardingWireframeInk.rose
                    let fade = motion.fade * (0.64 + 0.36 * (depth + 1) / 2)
                    let worldZ = motion.stage.value + depth * 0.28
                    let style = OnboardingWireStrokes.style(fade: fade, tint: tint, strength: 0.9, clock: motion.clock)
                    switch index {
                    case 0: OnboardingFinaleFigures.keyMotif.draw(in: &context, center: point, worldZ: worldZ, radius: radius,
                                                                  angles: angles, style: style)
                    case 1: OnboardingFinaleFigures.padlockMotif.draw(in: &context, center: point, worldZ: worldZ, radius: radius,
                                                                      angles: angles, style: style)
                    case 2: OnboardingFinaleFigures.globeMotif.draw(in: &context, center: point, worldZ: worldZ, radius: radius,
                                                                    angles: angles, style: style)
                    default:
                        let key = OnboardingFinaleFigures.commandMotif
                        key.cap.draw(in: &context, center: point, worldZ: worldZ, radius: radius, angles: angles, style: style)
                        OnboardingWireStrokes.draw(key.legend, in: &context, center: point, radius: radius, worldZ: worldZ,
                                                   angles: angles, fade: fade, tint: tint, width: 1.05)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
