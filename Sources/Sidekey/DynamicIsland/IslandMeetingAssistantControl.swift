import SwiftUI

/// Overrides automatic listening for this meeting; revealing it never toggles it.
struct IslandMeetingAssistantControl: View {
    static let size: CGFloat = 28
    let state: MeetingAssistantHoverState
    let setEnabled: (Bool) -> Void
    var hitBridge: IslandHoverHitBridge? = nil
    var hitContext = ""
    var reduceMotionOverride: Bool? = nil
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let hitBridge, state.canToggle {
                control.islandHoverHitTarget(bridge: hitBridge, id: .init(surface: .meetingAssistant, tool: .meetingAssistant),
                    context: hitContext, action: { setEnabled(!state.isOn) })
                    .islandHoverHitRegion(bridge: hitBridge, surface: .meetingAssistant)
            } else { control }
        }
        .frame(width: Self.size, height: Self.size)
    }

    private var control: some View {
        Button { setEnabled(!state.isOn) } label: {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: (reduceMotionOverride ?? reduceMotion) || state.phase != .listening)) { context in
                MeetingAssistantMagicGlyph(phase: state.phase,
                    glow: (reduceMotionOverride ?? reduceMotion) ? 0.65 : Self.glow(at: context.date.timeIntervalSinceReferenceDate))
            }
            .frame(width: Self.size, height: Self.size)
        }
        .buttonStyle(MeetingAssistantMagicFeedback(focused: focused))
        .focused($focused)
        .disabled(!state.canToggle)
        .help(state.isOn ? "Выключить Meeting Assistant для этой встречи" : "Включить Meeting Assistant для этой встречи")
        .accessibilityRepresentation {
            Toggle("Meeting Assistant — только эта встреча", isOn: Binding(get: { state.isOn }, set: setEnabled))
                .disabled(!state.canToggle)
                .accessibilityValue(Text("\(state.isOn ? "Включён" : "Выключен"). \(state.subtitle)"))
        }
    }

    /// Only the halo breathes; neither the glyph nor its target moves.
    static func glow(at time: TimeInterval) -> Double { 0.65 + 0.18 * sin(time * .pi * 2 / 3.2) }
}

struct MeetingAssistantMagicGlyph: View {
    let phase: MeetingAssistantHoverState.Phase
    var glow: Double = 0.65
    private var listening: Bool { phase == .listening }
    var body: some View {
        Image(systemName: "wand.and.stars")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(listening
                ? LinearGradient(colors: [.white, Color(red: 0.57, green: 0.81, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                : LinearGradient(colors: [.white.opacity(phase == .connecting ? 0.85 : 0.52), .white.opacity(phase == .connecting ? 0.85 : 0.52)], startPoint: .top, endPoint: .bottom))
            .shadow(color: Color(red: 0.30, green: 0.65, blue: 1).opacity(listening ? glow : 0), radius: 5)
            .shadow(color: Color(red: 0.30, green: 0.65, blue: 1).opacity(listening ? glow * 0.35 : 0), radius: 10)
            .overlay {
                if phase == .connecting {
                    Circle().trim(from: 0.08, to: 0.78).stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(width: 24, height: 24)
                }
            }
            .opacity(phase == .stopping ? 0.45 : 1)
            .accessibilityHidden(true)
    }
}

private struct MeetingAssistantMagicFeedback: ButtonStyle {
    let focused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.islandHoverNativePressed) private var nativePressed
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .background(MeetingAssistantHoverSurface(hovered: hovered, pressed: configuration.isPressed || nativePressed,
                focused: focused, enabled: enabled))
            .onHover { hovered = $0 }
    }
}

/// Shared by live interaction and offscreen feedback proofs.
struct MeetingAssistantHoverSurface: View {
    var hovered = false
    var pressed = false
    var focused = false
    var enabled = true
    var body: some View {
        RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(enabled ? (pressed ? 0.22 : hovered ? 0.12 : 0) : 0))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(enabled && focused ? .white.opacity(0.85) : .clear, lineWidth: 1.5))
            .allowsHitTesting(false)
    }
}

/// The existing right-agent reservation hosts this small hover-only extension.
/// Recording geometry and drawer height never move to make room for the icon.
enum IslandMeetingAssistantPlacement {
    static let extensionWidth: CGFloat = IslandMeetingAssistantControl.size + 8
    static func isVisible(recording: Bool, assistant: MeetingAssistantHoverState,
                          hoverExpanded: Bool, controls: Bool, obscured: Bool) -> Bool {
        hoverExpanded && controls && !obscured && assistant.visible
            && (recording || assistant.meetingActive || assistant.phase != .off)
    }
    static func frame(beside compact: CGRect) -> CGRect {
        CGRect(x: compact.maxX, y: compact.minY, width: extensionWidth, height: compact.height)
    }
}
