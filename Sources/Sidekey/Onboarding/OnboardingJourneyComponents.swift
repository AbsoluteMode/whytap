import AppKit
import SwiftUI

// The onboarding's components, from the design pass of 2026-11-22: a grouped
// progress rail, a fixed Back slot, the dwell pill, choice cards, the key
// slot, a single-permission screen, the Try Drop stage and the docked finale.
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

// MARK: - One permission

enum OnboardingPermissionPhase: Equatable {
    case ready
    case awaitingSystem
    case granted
}

/// A drawing of the System Settings row macOS asks about, and the action row:
/// Allow → Waiting for macOS (with Open Settings) → Granted.
struct OnboardingPermissionCard: View {
    let icon: String
    let title: String
    let purpose: String
    let section: String
    let phase: OnboardingPermissionPhase
    let request: () -> Void
    let recheck: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            settingsDrawing
            actionRow
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recheck() }
    }

    private var settingsDrawing: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(OnboardingTheme.trafficRed.opacity(0.75)).frame(width: 7.5, height: 7.5)
                Circle().fill(OnboardingTheme.trafficYellow.opacity(0.75)).frame(width: 7.5, height: 7.5)
                Circle().fill(OnboardingTheme.trafficGreen.opacity(0.75)).frame(width: 7.5, height: 7.5)
                Text(section)
                    .font(OnboardingTheme.mono(9.5, weight: .medium))
                    .tracking(0.7)
                    .foregroundColor(OnboardingTheme.faint)
                    .lineLimit(1)
                    .padding(.leading, 6)
                Spacer(minLength: 0)
                if phase == .awaitingSystem {
                    Text("TURN ON WHYTAP")
                        .font(OnboardingTheme.mono(9, weight: .semibold))
                        .foregroundColor(OnboardingTheme.orange)
                }
            }
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(OnboardingTheme.accent, lineWidth: 2).frame(width: 13, height: 13))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(OnboardingTheme.borderStrong, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Whytap").font(OnboardingTheme.sans(13, weight: .semibold)).foregroundColor(OnboardingTheme.ink)
                    Text(phase == .granted ? "Allowed" : "Switch it on when macOS asks")
                        .font(OnboardingTheme.sans(11))
                        .foregroundColor(OnboardingTheme.muted)
                }
                Spacer(minLength: 0)
                Capsule(style: .continuous)
                    .fill(phase == .granted ? OnboardingTheme.green : Color.white.opacity(0.14))
                    .frame(width: 36, height: 20)
                    .overlay(Circle().fill(Color.white).frame(width: 16, height: 16).offset(x: phase == .granted ? 8 : -8))
                    .animation(OnboardingMotion.resolve(OnboardingMotion.detent, reduceMotion: reduceMotion), value: phase)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(phase == .awaitingSystem ? OnboardingTheme.accent.opacity(0.09) : OnboardingTheme.recessed))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(phase == .granted ? OnboardingTheme.green.opacity(0.45)
                              : phase == .awaitingSystem ? OnboardingTheme.accent.opacity(0.55) : OnboardingTheme.border,
                              lineWidth: 0.75))
        }
        .padding(13)
        .onboardingElevatedCard(cornerRadius: 13)
        .accessibilityHidden(true)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(phase == .granted ? OnboardingTheme.green : OnboardingTheme.ink2)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(phase == .granted ? OnboardingTheme.green.opacity(0.12) : OnboardingTheme.surface3))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(OnboardingTheme.sans(13.5, weight: .semibold)).foregroundColor(OnboardingTheme.ink)
                Text(purpose)
                    .font(OnboardingTheme.sans(11.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch phase {
            case .ready:
                OnboardingPrimaryButton(title: "Allow", chevron: false, action: request)
                    .accessibilityLabel("Allow \(title)")
            case .awaitingSystem:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityLabel("Waiting for macOS")
                    OnboardingOutlineButton(title: "Open Settings", action: request).fixedSize()
                }
            case .granted:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18, weight: .medium))
                    Text("Allowed").font(OnboardingTheme.sans(12.5, weight: .semibold))
                }
                .foregroundColor(OnboardingTheme.green)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(13)
        .onboardingElevatedCard(cornerRadius: 13, isConfirmed: phase == .granted)
        .animation(OnboardingMotion.resolve(OnboardingMotion.slotMorph, reduceMotion: reduceMotion), value: phase)
    }
}

// MARK: - Try Drop

/// A note with a small island wing in its bar, the real dictation field (Drop
/// inserts into it like any app) and the person's own shortcut.
struct OnboardingTryStage: View {
    let shortcut: HotkeyShortcut
    let gesture: HotkeyGesture
    let dictated: Bool
    let problem: String?
    let onDictated: () -> Void
    /// The standalone preview has no Drop: a button stands in for it.
    var simulate: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let copy = OnboardingTryPage.Copy(shortcut: shortcut.title, gesture: gesture)
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    HStack(spacing: 5) {
                        Circle().fill(OnboardingTheme.trafficRed.opacity(0.75)).frame(width: 7.5, height: 7.5)
                        Circle().fill(OnboardingTheme.trafficYellow.opacity(0.75)).frame(width: 7.5, height: 7.5)
                        Circle().fill(OnboardingTheme.trafficGreen.opacity(0.75)).frame(width: 7.5, height: 7.5)
                        Spacer()
                        Text(dictated ? "PASTED AT THE CURSOR" : "NOTES")
                            .font(OnboardingTheme.mono(9.5, weight: dictated ? .semibold : .medium))
                            .foregroundColor(dictated ? OnboardingTheme.green : OnboardingTheme.faint)
                    }
                    .padding(.horizontal, 12)
                    wing
                }
                .frame(height: 32)
                .background(OnboardingTheme.surface2)
                .overlay(Rectangle().fill(OnboardingTheme.border).frame(height: 0.5), alignment: .bottom)
                OnboardingTryField(placeholder: copy.placeholder, onDictated: onDictated)
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108, alignment: .topLeading)
                    .background(OnboardingTheme.recessed)
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(dictated ? OnboardingTheme.green.opacity(0.60) : OnboardingTheme.borderStrong,
                              lineWidth: dictated ? 1.2 : 0.75))
            .animation(OnboardingMotion.resolve(OnboardingMotion.slotMorph, reduceMotion: reduceMotion), value: dictated)

            HStack(spacing: 12) {
                OnboardingKeycaps(contents: shortcut.contents)
                Text(problem ?? (dictated ? "That's Drop. The same shortcut works in any app's text field."
                                          : "\(copy.pressVerb) \(shortcut.title) in the note and say a sentence."))
                    .font(OnboardingTheme.sans(12))
                    .foregroundColor(problem != nil ? OnboardingTheme.orange : dictated ? OnboardingTheme.ink2 : OnboardingTheme.muted)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let simulate, !dictated {
                    OnboardingOutlineButton(title: "Simulate Drop", action: simulate).fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .onboardingElevatedCard(cornerRadius: 12, isConfirmed: dictated)
            .accessibilityElement(children: .combine)
        }
    }

    private var wing: some View {
        HStack(spacing: 6) {
            Circle().fill(dictated ? OnboardingTheme.green : OnboardingTheme.faint).frame(width: 6, height: 6)
            if dictated {
                Text("pasted").font(OnboardingTheme.mono(9.5, weight: .medium)).foregroundColor(OnboardingTheme.green)
            }
        }
        .padding(.horizontal, dictated ? 10 : 8)
        .frame(height: 20)
        .background(Capsule(style: .continuous).fill(Color.black))
        .overlay(Capsule(style: .continuous).strokeBorder(OnboardingTheme.borderStrong, lineWidth: 0.5))
        .animation(OnboardingMotion.resolve(OnboardingMotion.wingExpand, reduceMotion: reduceMotion), value: dictated)
    }
}

// MARK: - Finale

/// The island docking to the card's top edge, and a receipt of what was set.
struct OnboardingThankYouCard: View {
    let receipt: (speech: String, llm: String, language: String, access: String)
    let hint: String
    let finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var docked = false

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(OnboardingTheme.green).frame(width: 6, height: 6)
                    Text("Whytap island · ready")
                        .font(OnboardingTheme.mono(10, weight: .medium))
                        .foregroundColor(OnboardingTheme.ink)
                }
                .padding(.horizontal, 16)
                .frame(height: 24)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11, style: .continuous)
                    .fill(Color.black))
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11, style: .continuous)
                    .strokeBorder(OnboardingTheme.borderStrong, lineWidth: 0.75))
                .offset(y: docked || reduceMotion ? 0 : -14)
                .opacity(docked || reduceMotion ? 1 : 0)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    cell("SPEECH", receipt.speech)
                    cell("LANGUAGE MODEL", receipt.llm)
                    cell("LANGUAGE", receipt.language)
                    cell("ACCESS", receipt.access)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity)
            .onboardingElevatedCard(cornerRadius: 14)
            HStack {
                Text(hint)
                    .font(OnboardingTheme.sans(11.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineLimit(2)
                Spacer(minLength: 8)
                OnboardingPrimaryButton(title: "Start Whytap", chevron: false, action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            withAnimation(OnboardingMotion.resolve(OnboardingMotion.notchDock, reduceMotion: reduceMotion)) { docked = true }
        }
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(OnboardingTheme.mono(9, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(OnboardingTheme.faint)
            Text(value)
                .font(OnboardingTheme.sans(12, weight: .medium))
                .foregroundColor(OnboardingTheme.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(OnboardingTheme.recessed))
    }
}

// MARK: - Rows

/// A raised row with a title, a line of detail and trailing content.
struct OnboardingInfoRow<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(OnboardingTheme.sans(13.5, weight: .semibold)).foregroundColor(OnboardingTheme.ink)
                Text(detail).font(OnboardingTheme.sans(11.5)).foregroundColor(OnboardingTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .onboardingElevatedCard(cornerRadius: 12)
    }
}
