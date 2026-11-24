import SwiftUI

/// The balloon over Lil Bro (variant C): the question, his answer, the place
/// he opened and what to ask next. Earlier questions fold under "earlier";
/// the ⋯ menu hides the little guy, clears and closes.
@MainActor
struct LilBroBalloonView: View {
    static let width: CGFloat = 296
    @ObservedObject var controller: LilBroController
    let tail: LilBroBalloonLayout.Tail
    let tailOffset: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {
                    if controller.showEarlier { earlier }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: max(80, maxHeight - 44))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: Self.width, alignment: .leading)
        .background(LilBroBalloonShape(tail: tail, tailOffset: tailOffset).fill(MacSettingsTheme.bgCard))
        .overlay(LilBroBalloonShape(tail: tail, tailOffset: tailOffset)
            .stroke(MacSettingsTheme.sepStrong, lineWidth: 0.75))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .onExitCommand { controller.close() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lil Bro")
    }

    private var lastTurn: LilBroController.Turn? { controller.turns.last }

    private var header: some View {
        HStack(spacing: 6) {
            if let turn = lastTurn {
                Text("You:")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.text2)
                Text(turn.question)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Lil Bro")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 4)
            if controller.turns.count > 1 {
                Button(controller.showEarlier ? "hide ⌄" : "earlier ⌃") { controller.showEarlier.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .accessibilityLabel(controller.showEarlier ? "Hide earlier questions" : "Show earlier questions")
            }
            Menu {
                Button(controller.mascotVisible ? "Hide the little guy" : "Show the little guy") {
                    controller.setMascotVisible(!controller.mascotVisible)
                }
                Button(controller.answersFromWhytap ? "Turn off answers from whytap.ai" : "Turn on answers from whytap.ai") {
                    controller.setAnswersFromWhytap(!controller.answersFromWhytap)
                }
                if !controller.turns.isEmpty { Button("Clear") { controller.clear() } }
                Button("Close") { controller.close() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options")
            Button { controller.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder private var content: some View {
        if let turn = lastTurn, let reply = turn.reply {
            LilBroReplyView(reply: reply, question: turn.question, opened: turn.opened,
                            mascot: controller.mascotVisible, answersOn: controller.answersFromWhytap,
                            actions: actions, current: true)
        } else if controller.answersFromWhytap {
            paragraph(LilBroCopy.greetingAnswers)
            LilBroChips(items: LilBroLocalGuide.starters.map { q in (q, false, { controller.ask(q) }) })
            note(LilBroCopy.answersNote)
        } else {
            paragraph(LilBroCopy.greeting)
            LilBroChips(items: LilBroLocalGuide.starters.map { q in (q, false, { controller.ask(q) }) })
            LilBroOffer { controller.setAnswersFromWhytap(true) }
        }
    }

    private var actions: LilBroReplyView.Actions {
        LilBroReplyView.Actions(ask: controller.ask, retry: controller.retry, open: controller.open,
                                turnOn: { controller.setAnswersFromWhytap(true) })
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(MacSettingsTheme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var earlier: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.turns.dropLast()) { turn in
                VStack(alignment: .leading, spacing: 4) {
                    (Text("You: ").foregroundStyle(MacSettingsTheme.text2)
                        + Text(turn.question).fontWeight(.semibold).foregroundStyle(MacSettingsTheme.text))
                        .font(.system(size: 11.5))
                    if let reply = turn.reply {
                        LilBroReplyView(reply: reply, question: turn.question, opened: turn.opened,
                                        mascot: controller.mascotVisible, answersOn: controller.answersFromWhytap,
                                        actions: .none, current: false)
                    }
                }
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) { Rectangle().fill(MacSettingsTheme.sep).frame(height: 0.5) }
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(MacSettingsTheme.text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One reply's words: an answer with the place he opened, or why he could
/// not answer. Earlier replies show the words only.
struct LilBroReplyView: View {
    struct Actions {
        var ask: (String) -> Void
        var retry: () -> Void
        var open: (LilBroDestination) -> Void
        var turnOn: () -> Void

        static let none = Actions(ask: { _ in }, retry: {}, open: { _ in }, turnOn: {})
    }

    let reply: LilBroReply
    let question: String
    let opened: String?
    let mascot: Bool
    let answersOn: Bool
    let actions: Actions
    let current: Bool

    private var ask: (String) -> Void { actions.ask }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch reply {
            case .answer(let answer):
                ForEach(Array(answer.paragraphs.enumerated()), id: \.offset) { _, line in paragraph(line) }
                if !answer.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(answer.bullets.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(MacSettingsTheme.text2)
                                paragraph(line)
                            }
                        }
                    }
                }
                if let opened {
                    (Text(mascot ? "I opened " : "Opened ") + Text(opened).fontWeight(.semibold) + Text("."))
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text2)
                }
                if current, !answer.followUps.isEmpty {
                    LilBroChips(items: answer.followUps.map { q in (q, false, { ask(q) }) })
                }
            case .unknown(let suggestions):
                paragraph(LilBroCopy.unknown)
                if current { LilBroChips(items: suggestions.map { q in (q, false, { ask(q) }) }) }
                if current, !answersOn { LilBroOffer(turnOn: actions.turnOn) }
            case .offline:
                paragraph(LilBroCopy.offline)
                if current { LilBroChips(items: [("Try again", true, actions.retry)] + closest) }
            case .unavailable:
                paragraph(LilBroCopy.unavailable)
                if current { LilBroChips(items: [("Try again", true, actions.retry)] + closest) }
            case .limit:
                paragraph(LilBroCopy.limit)
                if current { LilBroChips(items: closest) }
            }
            if let opened, !isAnswer {
                (Text(mascot ? "I opened " : "Opened ") + Text(opened).fontWeight(.semibold) + Text("."))
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
        }
    }

    private var isAnswer: Bool {
        if case .answer = reply { return true }
        return false
    }

    /// "Open <page>" buttons when whytap.ai cannot answer.
    private var closest: [(String, Bool, () -> Void)] {
        let open = actions.open
        return LilBroLocalGuide.closestPlaces(for: question).map { place in
            ("Open \(place.title)", false, { open(place) })
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(MacSettingsTheme.text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The one place answers from whytap.ai are turned on: what goes there, what
/// stays on this Mac, and the button. Nothing is sent before it is pressed.
// WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md
struct LilBroOffer: View {
    let turnOn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(LilBroCopy.offer)
                .font(.system(size: 11.5))
                .foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
            LilBroChips(items: [(LilBroCopy.turnOn, true, turnOn)])
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(MacSettingsTheme.controlBg))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answers from whytap.ai")
    }
}

/// Rounded suggestion buttons that wrap to the balloon's width.
struct LilBroChips: View {
    let items: [(String, Bool, () -> Void)]

    var body: some View {
        LilBroFlow(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                LilBroChip(title: item.0, primary: item.1, action: item.2)
            }
        }
    }
}

struct LilBroChip: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primary ? Color.white : MacSettingsTheme.text)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(primary ? MacSettingsTheme.accentFill
                                           : (hovered ? MacSettingsTheme.hover : MacSettingsTheme.bgCard)))
                .overlay(Capsule().strokeBorder(primary ? Color.clear : MacSettingsTheme.sepStrong, lineWidth: 1))
                .overlay(Capsule().strokeBorder(MacSettingsTheme.accent, lineWidth: 2).opacity(focused ? 1 : 0))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Its own focus ring follows the capsule; the default one is square.
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hovered = $0 }
    }
}

/// A left-to-right wrapping row.
struct LilBroFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// The reply field beside his feet: type, send, and an (i) that says where
/// the question goes.
@MainActor
struct LilBroReplyField: View {
    static let width: CGFloat = 210
    @ObservedObject var controller: LilBroController
    @FocusState private var focused: Bool
    @State private var info = false

    var body: some View {
        HStack(spacing: 4) {
            TextField(LilBroCopy.placeholder, text: $controller.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit { controller.ask(controller.draft) }
                .accessibilityLabel("Ask Lil Bro")
            Button { controller.ask(controller.draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(controller.draft.trimmingCharacters(in: .whitespaces).isEmpty
                                              ? MacSettingsTheme.text3 : MacSettingsTheme.accentFill))
            }
            .buttonStyle(.plain)
            .disabled(controller.draft.trimmingCharacters(in: .whitespaces).isEmpty || controller.isBusy)
            .accessibilityLabel("Send")
            Button { info.toggle() } label: {
                Image(systemName: "info")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(MacSettingsTheme.controlBg))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Where questions go")
            .popover(isPresented: $info, arrowEdge: .top) {
                Text(controller.answersFromWhytap ? LilBroCopy.answersNote : LilBroCopy.localNote)
                    .font(.system(size: 12))
                    .frame(width: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(width: Self.width, height: 30)
        .background(Capsule().fill(MacSettingsTheme.fieldBg))
        .overlay(Capsule().strokeBorder(focused ? MacSettingsTheme.accent : MacSettingsTheme.sepStrong,
                                        lineWidth: focused ? 1.5 : 0.75))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        .onExitCommand { controller.close() }
        .onAppear { focused = true }
    }
}

/// A rounded balloon with a small tail toward Lil Bro.
struct LilBroBalloonShape: Shape {
    let tail: LilBroBalloonLayout.Tail
    let tailOffset: CGFloat
    var radius: CGFloat = 14
    var tailSize: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        var tailPath = Path()
        switch tail {
        case .down:
            let x = rect.minX + tailOffset
            tailPath.move(to: CGPoint(x: x - tailSize, y: rect.maxY - 0.5))
            tailPath.addLine(to: CGPoint(x: x, y: rect.maxY + tailSize))
            tailPath.addLine(to: CGPoint(x: x + tailSize, y: rect.maxY - 0.5))
        case .up:
            let x = rect.minX + tailOffset
            tailPath.move(to: CGPoint(x: x - tailSize, y: rect.minY + 0.5))
            tailPath.addLine(to: CGPoint(x: x, y: rect.minY - tailSize))
            tailPath.addLine(to: CGPoint(x: x + tailSize, y: rect.minY + 0.5))
        case .left:
            let y = rect.minY + tailOffset
            tailPath.move(to: CGPoint(x: rect.minX + 0.5, y: y - tailSize))
            tailPath.addLine(to: CGPoint(x: rect.minX - tailSize, y: y))
            tailPath.addLine(to: CGPoint(x: rect.minX + 0.5, y: y + tailSize))
        case .right:
            let y = rect.minY + tailOffset
            tailPath.move(to: CGPoint(x: rect.maxX - 0.5, y: y - tailSize))
            tailPath.addLine(to: CGPoint(x: rect.maxX + tailSize, y: y))
            tailPath.addLine(to: CGPoint(x: rect.maxX - 0.5, y: y + tailSize))
        }
        tailPath.closeSubpath()
        path.addPath(tailPath)
        return path
    }
}
