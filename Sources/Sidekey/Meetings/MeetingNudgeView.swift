import SwiftUI

enum MeetingNudgeAction: Equatable {
    case takeNotes
    case reconnect
    case skip
    case timedOut
}

/// Hover-aware two-action nudge shown below Dynamic Island when a meeting
/// is detected.
///
/// The countdown lives in the view because hover pauses the drain. The
/// controller only receives the final action and routes it to the
/// meetings coordinator.
struct MeetingNudgeView: View {
    var duration: TimeInterval = 20
    var width: CGFloat = 312
    var height: CGFloat = 32
    var split: CGFloat = 0.60
    var reconnectGapSeconds: TimeInterval?
    var onAction: (MeetingNudgeAction) -> Void

    private let bgLight = Color.white
    private let bgDark = Color.black
    private let inkLight = Color(red: 0.04, green: 0.04, blue: 0.04)
    private let inkDark = Color.white

    @State private var leaving = false
    @State private var hover: Side?
    @State private var press: Side?

    private enum Side {
        case light
        case dark
    }

    init(
        duration: TimeInterval = 20,
        width: CGFloat = 312,
        height: CGFloat = 32,
        split: CGFloat = 0.60,
        reconnectGapSeconds: TimeInterval? = nil,
        onAction: @escaping (MeetingNudgeAction) -> Void
    ) {
        self.duration = duration
        self.width = width
        self.height = height
        self.split = split
        self.reconnectGapSeconds = reconnectGapSeconds
        self.onAction = onAction
    }

    var body: some View {
        Group {
            if let reconnectGapSeconds {
                reconnectContent(gapSeconds: reconnectGapSeconds)
            } else {
                standardContent
            }
        }
    }

    private var standardContent: some View {
        let lightWidth = currentLightWidth()
        let darkWidth = width - lightWidth

        return ZStack {
            HStack(spacing: 0) {
                bgLight.frame(width: lightWidth)
                bgDark.frame(width: darkWidth)
            }

            HStack(spacing: 0) {
                Button {
                    dismiss(.takeNotes)
                } label: {
                    Text("Take notes")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(inkLight)
                        .frame(width: lightWidth, height: height)
                        .opacity(hover == .dark ? 0 : 1)
                        .contentShape(Rectangle())
                        .scaleEffect(press == .light ? 0.985 : 1)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    setHover(hovering ? .light : (hover == .light ? nil : hover))
                }
                .pressableGesture { isPressed in
                    press = isPressed ? .light : nil
                }

                Button {
                    dismiss(.skip)
                } label: {
                    Text("Skip")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(inkDark)
                        .frame(width: darkWidth, height: height)
                        .opacity(hover == .light ? 0 : 1)
                        .contentShape(Rectangle())
                        .scaleEffect(press == .dark ? 0.985 : 1)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    setHover(hovering ? .dark : (hover == .dark ? nil : hover))
                }
                .pressableGesture { isPressed in
                    press = isPressed ? .dark : nil
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: MeetingPillPanel.suggestionNudgeTopCornerRadius,
                bottomLeadingRadius: height / 2,
                bottomTrailingRadius: height / 2,
                topTrailingRadius: MeetingPillPanel.suggestionNudgeTopCornerRadius,
                style: .continuous
            )
        )
        .scaleEffect(y: leaving ? 0.86 : 1, anchor: .top)
        .offset(y: leaving ? -6 : 0)
        .opacity(leaving ? 0 : 1)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: hover)
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: leaving)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting detected, take notes or skip")
        .background(KeyEventHandler { key in
            switch key {
            case .return:
                dismiss(.takeNotes)
            case .escape:
                dismiss(.skip)
            }
        })
        // Single one-shot timeout instead of a per-frame countdown timer.
        // The previous 60 Hz `Timer.publish` re-evaluated this body every
        // 16 ms for the nudge's whole lifetime — measured ~6% CPU of main
        // on an M4 — exactly while meeting start already saturates the
        // main thread. Nothing here renders the remaining time (the
        // countdown ring lives in the island's right band), so one sleep
        // until the deadline is behaviorally identical. The task is
        // cancelled automatically when the view unmounts; `dismiss`
        // guards `leaving` for the click-then-timeout race.
        // WHY: docs/decisions/2026-07-08-meeting-audio-hal-scan-off-main.md
        .task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            dismiss(.timedOut)
        }
    }

    private func reconnectContent(gapSeconds: TimeInterval) -> some View {
        HStack(spacing: 0) {
            reconnectButton(
                title: "Notes",
                subtitle: nil,
                foreground: inkLight,
                background: bgLight,
                action: .takeNotes,
                width: width * 0.30
            )
            reconnectButton(
                title: "Reconnect",
                subtitle: Self.gapLabel(gapSeconds),
                foreground: .white,
                background: Color(red: 0.18, green: 0.43, blue: 0.96),
                action: .reconnect,
                width: width * 0.48
            )
            reconnectButton(
                title: "Skip",
                subtitle: nil,
                foreground: inkDark,
                background: bgDark,
                action: .skip,
                width: width * 0.22
            )
        }
        .frame(width: width, height: height)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: MeetingPillPanel.suggestionNudgeTopCornerRadius,
                bottomLeadingRadius: height / 2,
                bottomTrailingRadius: height / 2,
                topTrailingRadius: MeetingPillPanel.suggestionNudgeTopCornerRadius,
                style: .continuous
            )
        )
        .scaleEffect(y: leaving ? 0.86 : 1, anchor: .top)
        .offset(y: leaving ? -6 : 0)
        .opacity(leaving ? 0 : 1)
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: leaving)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting detected, notes, reconnect, or skip")
        .background(KeyEventHandler { key in
            switch key {
            case .return: dismiss(.reconnect)
            case .escape: dismiss(.skip)
            }
        })
        .task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            dismiss(.timedOut)
        }
    }

    private func reconnectButton(
        title: String,
        subtitle: String?,
        foreground: Color,
        background: Color,
        action: MeetingNudgeAction,
        width: CGFloat
    ) -> some View {
        Button { dismiss(action) } label: {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: subtitle == nil ? 13 : 12, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .opacity(0.78)
                }
            }
            .foregroundStyle(foreground)
            .frame(width: width, height: height)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    static func gapLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remainder = total % 60
        return minutes > 0 ? "after \(minutes)m \(remainder)s" : "after \(remainder)s"
    }

    private func currentLightWidth() -> CGFloat {
        switch hover {
        case .light:
            width
        case .dark:
            0
        case nil:
            width * split
        }
    }

    private func setHover(_ side: Side?) {
        if hover != side {
            hover = side
        }
    }

    private func dismiss(_ action: MeetingNudgeAction) {
        guard !leaving else { return }
        leaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            onAction(action)
        }
    }
}

struct MeetingNudgeHostView: View {
    let meetingId: UUID
    let duration: TimeInterval
    var reconnectGapSeconds: TimeInterval? = nil
    let onAction: (MeetingNudgeAction) -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                MeetingNudgeView(
                    duration: duration,
                    width: proxy.size.width,
                    height: MeetingPillPanel.suggestionNudgeHeight,
                    reconnectGapSeconds: reconnectGapSeconds,
                    onAction: onAction
                )
                .id(meetingId)
                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }
}

private struct PressableGesture: ViewModifier {
    var onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onChange(true) }
                .onEnded { _ in onChange(false) }
        )
    }
}

private extension View {
    func pressableGesture(_ onChange: @escaping (Bool) -> Void) -> some View {
        modifier(PressableGesture(onChange: onChange))
    }
}

#if canImport(AppKit)
import AppKit

private enum NudgeKey {
    case `return`
    case escape
}

private struct KeyEventHandler: NSViewRepresentable {
    var handler: (NudgeKey) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.handler = handler
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyView)?.handler = handler
    }

    final class KeyView: NSView {
        var handler: ((NudgeKey) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76:
                handler?(.return)
            case 53:
                handler?(.escape)
            default:
                super.keyDown(with: event)
            }
        }
    }
}
#endif
