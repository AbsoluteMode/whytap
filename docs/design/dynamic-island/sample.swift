// Reference port from claude.ai/design bundle — see /docs/design/dynamic-island/preview.html for live HTML preview.
import SwiftUI

// MARK: - Sidekey · Dynamic Island
//
// Top-of-screen pill (compact: 240 × 28). Identity ring on the left,
// state-driven indicator on the right. On hover the pill grows DOWNWARD
// into a 360 × 152 panel showing the same state's expanded affordances —
// transcript + actions for listening, full answer card for `.answer`,
// a 5-slot picker for `.picker`, etc.
//
// Mirrors `dynamic-island.jsx` from the Sidekey design canvas (section
// "05 · Dynamic Island"). Tokens come from `tokens.css`.
//
// Usage:
//     SidekeyDynamicIsland(state: .listening)
//         .frame(maxWidth: .infinity, alignment: .top)
//         .padding(.top, 4)   // sit just below the menu bar

public enum IslandState: String, CaseIterable, Sendable {
    case idle, listening, thinking, answer, muted, picker
}

public struct SidekeyDynamicIsland: View {
    public var state: IslandState = .idle
    public var lang: Lang = .en

    public enum Lang: String, Sendable { case en, ru }

    // Tokens (mirrors dynamic-island.jsx + tokens.css)
    private let compactSize  = CGSize(width: 240, height: 28)
    private let expandedSize = CGSize(width: 360, height: 152)
    private let compactRadius:  CGFloat = 14   // h / 2
    private let expandedRadius: CGFloat = 22

    @State private var isOpen = false
    @State private var listeningSecs: Int = 4   // demo only

    // Sidekey motion tokens (--sk-spring)
    private let openMotion  = Animation.spring(response: 0.42, dampingFraction: 0.78)
    private let closeMotion = Animation.spring(response: 0.36, dampingFraction: 0.86)

    public init(state: IslandState = .idle, lang: Lang = .en) {
        self.state = state
        self.lang  = lang
    }

    public var body: some View {
        // Top-anchored container so growth happens downward, not from the center.
        VStack(spacing: 0) {
            ZStack {
                // Pill body — pure black, hairline rim, deep shadow.
                RoundedRectangle(cornerRadius: isOpen ? expandedRadius : compactRadius,
                                 style: .continuous)
                    .fill(.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: isOpen ? expandedRadius : compactRadius,
                                         style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.40), radius: 22, x: 0, y: 10)

                if isOpen {
                    ExpandedPanel(state: state, lang: lang, secs: listeningSecs)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else {
                    CompactRow(state: state, lang: lang, secs: listeningSecs)
                        .padding(.leading, 5)
                        .padding(.trailing, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .frame(
                width:  isOpen ? expandedSize.width  : compactSize.width,
                height: isOpen ? expandedSize.height : compactSize.height,
                alignment: .top
            )
            .animation(isOpen ? openMotion : closeMotion, value: isOpen)
            // Hover on macOS / iPadOS w/ pointer
            .onHover { hovering in isOpen = hovering }
            // Tap-to-toggle for touch
            .onTapGesture { isOpen.toggle() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sidekey · \(state.rawValue)")
            .accessibilityAddTraits(.isButton)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // Drive the demo timer when listening — purely cosmetic.
        .task(id: state) {
            guard state == .listening else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                listeningSecs += 1
            }
        }
    }
}

// MARK: - Identity ring (left side, always present)

private struct IdentityRing: View {
    var thinking: Bool = false
    var size: CGFloat = 18

    @State private var breathe = false
    @State private var orbit:  Double = 0

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.2)
                .frame(width: size, height: size)
                .shadow(color: .white.opacity(0.32), radius: 2.5)
                .scaleEffect(breathe ? 0.97 : 1.0)
                .opacity(breathe ? 1.0 : 0.92)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                           value: breathe)

            if thinking {
                // Orbiting dot — matches `.fo-orbit` in flat-orb.jsx
                Circle()
                    .fill(.white)
                    .frame(width: 4.5, height: 4.5)
                    .shadow(color: .white, radius: 2.5)
                    .offset(y: -(size / 2 - 0.5))
                    .rotationEffect(.degrees(orbit))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            breathe = true
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                orbit = 360
            }
        }
    }
}

// MARK: - Compact row (240 × 28)

private struct CompactRow: View {
    let state: IslandState
    let lang:  SidekeyDynamicIsland.Lang
    let secs:  Int

    var body: some View {
        HStack(spacing: 8) {
            IdentityRing(thinking: state == .thinking)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                stateIndicator
            }
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch state {
        case .idle:
            Text(lang == .ru ? "нажми ⌥/" : "press ⌥/")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))

        case .listening:
            RecPulse()
            Text(formatSecs(secs))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.65))
            Waveform()

        case .thinking:
            Text(lang == .ru ? "Думаю" : "Thinking")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            ThinkingDots()
                .foregroundStyle(.white.opacity(0.9))

        case .answer:
            Text(lang == .ru ? "Ответ готов" : "Answer ready")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
            ReturnChip()

        case .muted:
            HStack(spacing: 5) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                Text(lang == .ru ? "пауза" : "paused")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.5))

        case .picker:
            HStack(spacing: 3) {
                ForEach(PickerItem.demo, id: \.self) { it in
                    PickerSlot(item: it)
                }
            }
        }
    }

    private func formatSecs(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Expanded panel (360 × 152) — appears on hover

private struct ExpandedPanel: View {
    let state: IslandState
    let lang:  SidekeyDynamicIsland.Lang
    let secs:  Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row: ring + state title + meta on the right
            HStack(spacing: 10) {
                IdentityRing(thinking: state == .thinking, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                trailing
            }

            // Body — state-specific
            Group {
                switch state {
                case .idle:     IdleBody(lang: lang)
                case .listening: ListeningBody(secs: secs)
                case .thinking: ThinkingBody(lang: lang)
                case .answer:   AnswerBody(lang: lang)
                case .muted:    MutedBody(lang: lang)
                case .picker:   PickerBody()
                }
            }
            .padding(.top, 12)
        }
    }

    private var title: String {
        switch state {
        case .idle:      return lang == .ru ? "Sidekey" : "Sidekey"
        case .listening: return lang == .ru ? "Слушаю…" : "Listening…"
        case .thinking:  return lang == .ru ? "Думаю" : "Thinking"
        case .answer:    return lang == .ru ? "Готово" : "Answer ready"
        case .muted:     return lang == .ru ? "На паузе" : "Paused"
        case .picker:    return lang == .ru ? "Быстрые действия" : "Quick controls"
        }
    }
    private var subtitle: String {
        switch state {
        case .idle:      return lang == .ru ? "Hold ⌥/ to talk" : "Hold ⌥/ to talk"
        case .listening: return lang == .ru ? "диктовка · ru" : "dictation · en"
        case .thinking:  return "claude-sonnet-4.5"
        case .answer:    return lang == .ru ? "GitHub · summarize PR" : "GitHub · summarize PR"
        case .muted:     return lang == .ru ? "снова ⌥/" : "press ⌥/ to resume"
        case .picker:    return lang == .ru ? "выбери режим" : "pick a mode"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .listening:
            HStack(spacing: 6) {
                RecPulse()
                Text(String(format: "%d:%02d", secs / 60, secs % 60))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .thinking:
            ThinkingDots().foregroundStyle(.white.opacity(0.85))
        case .answer:
            ReturnChip()
        default:
            EmptyView()
        }
    }
}

// MARK: - Per-state expanded bodies

private struct IdleBody: View {
    let lang: SidekeyDynamicIsland.Lang
    var body: some View {
        HStack(spacing: 6) {
            ForEach(PickerItem.demo, id: \.self) { PickerSlot(item: $0, size: 30) }
            Spacer(minLength: 0)
            KbdChip(text: "⌥/")
        }
    }
}

private struct ListeningBody: View {
    let secs: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Live transcript skeleton
            Text("Summarize the GitHub PR I opened ten minutes ago and …")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)

            HStack(spacing: 8) {
                BigWaveform()
                Spacer(minLength: 0)
                IslandButton(label: "Cancel", kind: .ghost)
                IslandButton(label: "Send", kind: .primary)
            }
        }
    }
}

private struct ThinkingBody: View {
    let lang: SidekeyDynamicIsland.Lang
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Streaming skeleton lines
            SkelLine(width: 220)
            SkelLine(width: 180)
            SkelLine(width: 140)
            HStack {
                Spacer()
                Text(lang == .ru ? "0:08" : "0:08")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

private struct AnswerBody: View {
    let lang: SidekeyDynamicIsland.Lang
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adds a `--zoom` flag to the canvas viewport, persists the value to localStorage, and updates the toolbar % control.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                IslandButton(label: "Copy",   kind: .ghost)
                IslandButton(label: "Insert", kind: .primary)
            }
        }
    }
}

private struct MutedBody: View {
    let lang: SidekeyDynamicIsland.Lang
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
            Text(lang == .ru
                 ? "Сайдкей не слушает. Нажми ⌥/ или ткни сюда."
                 : "Sidekey is paused. Press ⌥/ or click here.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

private struct PickerBody: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(PickerItem.demo, id: \.self) { PickerSlot(item: $0, size: 38, showLabel: true) }
        }
    }
}

// MARK: - Atoms

private struct RecPulse: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color(red: 1.0, green: 0.36, blue: 0.36))
            .frame(width: 5, height: 5)
            .shadow(color: Color(red: 1.0, green: 0.36, blue: 0.36).opacity(0.7), radius: 2)
            .opacity(on ? 1 : 0.55)
            .scaleEffect(on ? 1.0 : 0.85)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private struct Waveform: View {
    let bars: [CGFloat] = [0.4, 0.7, 1.0, 0.85, 0.55, 0.4]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/60.0, paused: false)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(bars.indices, id: \.self) { i in
                    let phase = t * 6.5 + Double(i) * 0.6
                    let h = 0.25 + (sin(phase) * 0.5 + 0.5) * bars[i] * 0.75
                    Capsule()
                        .fill(.white.opacity(0.92))
                        .frame(width: 1.7, height: 10)
                        .scaleEffect(y: h, anchor: .center)
                }
            }
        }
        .frame(height: 10)
    }
}

private struct BigWaveform: View {
    let bars: [CGFloat] = [0.3, 0.5, 0.85, 1.0, 0.7, 0.5, 0.4, 0.6, 0.9, 0.7, 0.5, 0.35]
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(bars.indices, id: \.self) { i in
                    let phase = t * 6 + Double(i) * 0.5
                    let h = 0.25 + (sin(phase) * 0.5 + 0.5) * bars[i]
                    Capsule()
                        .fill(.white)
                        .frame(width: 2, height: 22)
                        .scaleEffect(y: h, anchor: .center)
                }
            }
        }
        .frame(height: 22)
    }
}

private struct ThinkingDots: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(.currentColor)
                    .frame(width: 4, height: 4)
                    .opacity(phase == i ? 1.0 : 0.25)
                    .offset(y: phase == i ? -2 : 0)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.3)) { phase = (phase + 1) % 3 }
            }
        }
    }
}
// SwiftUI's `currentColor` analog
private extension ShapeStyle where Self == Color {
    static var currentColor: Color { .primary }
}

private struct ReturnChip: View {
    var body: some View {
        Text("↵")
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .frame(minWidth: 16, minHeight: 16)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(Color.white.opacity(0.18))
            )
    }
}

private struct KbdChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            )
    }
}

private struct SkelLine: View {
    let width: CGFloat
    @State private var shimmer = false
    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.10),
                        Color.white.opacity(0.22),
                        Color.white.opacity(0.10),
                    ],
                    startPoint: shimmer ? .leading : .trailing,
                    endPoint:   shimmer ? .trailing : .leading
                )
            )
            .frame(width: width, height: 8)
            .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: shimmer)
            .onAppear { shimmer = true }
    }
}

// MARK: - Picker slot

private struct PickerItem: Hashable {
    let symbol: String
    let label:  String
    let active: Bool
    static let demo: [PickerItem] = [
        .init(symbol: "text.bubble",       label: "Dictation", active: false),
        .init(symbol: "waveform",          label: "Voice",     active: true),
        .init(symbol: "text.cursor",       label: "Text",      active: false),
        .init(symbol: "pause.fill",        label: "Pause",     active: false),
        .init(symbol: "eye.slash",         label: "Hide",      active: false),
    ]
}

private struct PickerSlot: View {
    let item: PickerItem
    var size: CGFloat = 22
    var showLabel: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(item.active ? Color.white.opacity(0.95) : Color.white.opacity(0.0))
                Image(systemName: item.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(item.active ? Color(red: 0.05, green: 0.05, blue: 0.06)
                                                 : Color.white.opacity(0.78))
            }
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(Color.white.opacity(item.active ? 0 : 0.08), lineWidth: 0.5)
            )

            if showLabel {
                Text(item.label)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(item.active ? 0.85 : 0.45))
            }
        }
    }
}

// MARK: - Buttons

private struct IslandButton: View {
    enum Kind { case primary, ghost }
    let label: String
    let kind:  Kind

    var body: some View {
        Text(label)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(kind == .primary ? Color(red: 0.05, green: 0.05, blue: 0.06)
                                              : Color.white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(kind == .primary ? Color.white : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(kind == .primary ? 0 : 0.10), lineWidth: 0.5)
            )
    }
}

// MARK: - Preview

#Preview("All states") {
    ZStack {
        // Mock macOS wallpaper, matching tokens.css `.sk-stage-desktop`
        LinearGradient(
            colors: [
                Color(red: 0.16, green: 0.12, blue: 0.24),
                Color(red: 0.04, green: 0.03, blue: 0.09),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()

        VStack(spacing: 14) {
            ForEach(IslandState.allCases, id: \.self) { st in
                HStack {
                    Text(st.rawValue)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 80, alignment: .leading)
                    SidekeyDynamicIsland(state: st, lang: .en)
                        .frame(width: 240, height: 28, alignment: .top)
                }
            }
            Spacer()
        }
        .padding(40)
    }
}
