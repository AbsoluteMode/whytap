import AppKit
import SwiftUI

// The onboarding's components, from the design pass of 2026-11-22: a grouped
// progress rail, a fixed Back slot, choice cards and badges. The steps' own
// stages live beside them (OnboardingAccessStage, OnboardingFinaleStages).
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md

// MARK: - Progress rail

/// One micro-segment per step, grouped by act with wider gaps. The current
/// segment fills during the dwell and turns amber while it is held; skipped
/// or unnecessary steps are hollow, never a false "done".
struct OnboardingProgressRail: View {
    let segments: [OnboardingSegment]
    var dwellFraction: Double = 0
    var isLatched = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One row of equal cells; a wider gap opens each act after the first.
        HStack(spacing: 2.5) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                cell(segment)
                    .padding(.leading, index > 0 && segments[index - 1].step.act != segment.step.act ? 4 : 0)
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private func cell(_ segment: OnboardingSegment) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                switch segment.state {
                case .upcoming:
                    Capsule(style: .continuous).fill(Color.white.opacity(0.09))
                case .bypassed:
                    Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                case .completed:
                    Capsule(style: .continuous).fill(OnboardingTheme.green.opacity(0.82))
                case .revisited:
                    // Still done: full green, lifted by a soft glow and a
                    // light rim, so it reads "you are here" without restarting.
                    Capsule(style: .continuous).fill(OnboardingTheme.green)
                        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.55), lineWidth: 0.6))
                        .shadow(color: OnboardingTheme.green.opacity(0.75), radius: 3.5)
                case .current:
                    Capsule(style: .continuous).fill(Color.white.opacity(0.22))
                    Capsule(style: .continuous)
                        .fill(isLatched ? OnboardingTheme.orange.opacity(0.85) : OnboardingTheme.ink)
                        .frame(width: max(dwellFraction > 0 ? 3 : proxy.size.width * 0.35,
                                          proxy.size.width * min(1, max(0, dwellFraction))))
                }
            }
        }
        .frame(height: 2.5)
        .animation(OnboardingMotion.resolve(OnboardingMotion.detent, reduceMotion: reduceMotion), value: segment.state)
    }

    private var summary: String {
        let index = (segments.firstIndex { $0.state == .current || $0.state == .revisited } ?? 0) + 1
        return "Step \(index) of \(segments.count)"
    }
}

// MARK: - Back

/// A fixed 32 × 24 pt slot: hidden on the first step without moving the rail.
/// 6% fill at rest, 15% on hover, 23% pressed, accent ring with keyboard focus.
struct OnboardingBackButton: View {
    let isVisible: Bool
    let destination: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        ZStack {
            if isVisible {
                Button(action: action) {
                    EmptyView()
                }
                .buttonStyle(OnboardingPressStyle { pressed in
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(OnboardingTheme.ink.opacity(pressed ? 0.92 : 0.86))
                        .frame(width: 32, height: 24)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(pressed ? 0.23 : hovered ? 0.15 : 0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(focused ? OnboardingTheme.accent : OnboardingTheme.border,
                                          lineWidth: focused ? 1.5 : 0.5))
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .animation(OnboardingMotion.resolve(pressed ? OnboardingMotion.pressIn : OnboardingMotion.pressRelease,
                                                            reduceMotion: reduceMotion), value: pressed)
                })
                .focusEffectDisabled()
                .focused($focused)
                .onHover { hovered = $0 }
                .help("Back (← or ⌘[)")
                .accessibilityLabel(destination.map { "Back to \($0)" } ?? "Back")
            }
        }
        .frame(width: 32, height: 24)
    }
}

// MARK: - Choice card

/// A raised slab with a recessed spec header; the chosen one locks with an
/// accent border and a drawn check, the other dims.
struct OnboardingChoiceCard<Header: View>: View {
    let title: String
    let summary: String
    let spec: String
    let isSelected: Bool
    let isDimmed: Bool
    let action: () -> Void
    @ViewBuilder let header: Header
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(OnboardingPressStyle { pressed in
                VStack(alignment: .leading, spacing: 12) {
                    header
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .onboardingRecessed(cornerRadius: 9, lineWidth: 0.5)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(OnboardingTheme.sans(14.5, weight: .semibold))
                                .foregroundColor(OnboardingTheme.ink)
                            Spacer(minLength: 0)
                            OnboardingSelectionMark(isSelected: isSelected)
                        }
                        Text(summary)
                            .font(OnboardingTheme.sans(12))
                            .foregroundColor(OnboardingTheme.muted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Rectangle().fill(OnboardingTheme.border).frame(height: 0.5)
                    Text(spec)
                        .font(OnboardingTheme.mono(10, weight: .medium))
                        .foregroundColor(isSelected ? OnboardingTheme.ink2 : OnboardingTheme.faint)
                        .lineLimit(1)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 196, maxHeight: 196, alignment: .topLeading)
                .onboardingElevatedCard(cornerRadius: 14, isSelected: isSelected, isHovered: hovered, isPressed: pressed)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(focused ? OnboardingTheme.accent : .clear, lineWidth: 2))
                .opacity(isDimmed ? 0.52 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .animation(OnboardingMotion.resolve(pressed ? OnboardingMotion.pressIn : OnboardingMotion.pressRelease,
                                                    reduceMotion: reduceMotion), value: pressed)
            })
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hovered = $0 }
            .animation(OnboardingMotion.resolve(OnboardingMotion.detent, reduceMotion: reduceMotion), value: isSelected)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct OnboardingSelectionMark: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? OnboardingTheme.accent : OnboardingTheme.borderStrong, lineWidth: 1.2)
                .background(Circle().fill(isSelected ? OnboardingTheme.accent : .clear))
                .frame(width: 18, height: 18)
            if isSelected {
                OnboardingCheckmarkShape()
                    .stroke(OnboardingTheme.ink, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 8, height: 6.5)
                    .transition(.opacity)
            }
        }
    }
}

/// A small mono badge: OFFLINE, OPTIONAL.
struct OnboardingBadge: View {
    let text: String
    var tint: Color = OnboardingTheme.green

    var body: some View {
        Text(text)
            .font(OnboardingTheme.mono(9, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// The model on this Mac while the person goes on through onboarding: one
/// line with the percent or the preparation and the time left, a thin line
/// under it, and a Ready moment when Drop works. Its height never changes
/// between the states, so the footer does not jump.
// WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
struct OnboardingModelProgressStrip: View {
    @ObservedObject var onDevice: OnDeviceSpeechModelController

    /// The strip's line for a state; nil hides the strip.
    static func line(_ status: OnDeviceSpeechModelStatus, timeLeft: OnDeviceSpeechTimeLeft?) -> String? {
        let left = OnDeviceSpeechProgressText.timeLeft(timeLeft ?? .estimating)
        switch status {
        case .downloading(let fraction):
            return OnDeviceSpeechCard.Presentation.isStarting(fraction)
                ? "Speech model · starting the download"
                : "Speech model · \(OnDeviceSpeechCard.Presentation.percent(fraction))% · \(left)"
        case .preparing: return "Speech model · preparing · \(left)"
        case .ready: return "Speech model ready · Drop works now"
        case .loadFailed: return "Speech model didn't load · try again in Settings"
        case .notDownloaded, .failed: return nil
        }
    }

    var body: some View {
        if let line = Self.line(onDevice.status, timeLeft: onDevice.timeLeft) {
            HStack(spacing: 7) {
                // The slot stays when hidden, so Ready does not move the text.
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(OnboardingTheme.green)
                    .opacity(onDevice.status == .ready ? 1 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(line)
                        .font(OnboardingTheme.sans(11))
                        .foregroundColor(onDevice.status == .ready ? OnboardingTheme.ink2 : OnboardingTheme.faint)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    bar
                        .frame(width: 150)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Speech model")
            .accessibilityValue(line)
        }
    }

    @ViewBuilder private var bar: some View {
        switch onDevice.status {
        case .downloading(let fraction):
            OnboardingProgressLine(fraction: fraction, indeterminate: OnDeviceSpeechCard.Presentation.isStarting(fraction))
        case .preparing:
            OnboardingProgressLine(fraction: 0, indeterminate: true)
        default:
            // Keeps the height of the line it replaces.
            OnboardingProgressLine(fraction: 1).opacity(0)
        }
    }
}
