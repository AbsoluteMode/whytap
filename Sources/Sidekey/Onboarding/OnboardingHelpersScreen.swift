import SwiftUI

/// "Helpers" onboarding step — showcases Whytap's background helpers. The
/// left column shows three selectable feature cards; the right pane shows
/// the demo for the selected feature.
struct OnboardingHelpersScreen: View {
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var stage = 0
    @State private var nudgeDrain: CGFloat = 1
    /// Drives the scripted "Take notes" choice in the nudge: once set, the
    /// light half expands to full width and Skip fades out — mirroring
    /// `MeetingNudgeView`'s hover behaviour on prod.
    @State private var nudgeChosen = false
    @State private var nudgePress = false
    /// Anchor for the recording-stage timer; reset each time recording starts.
    @State private var recordingStart = Date()
    /// Which feature card is selected.
    @State private var feature: Feature = .meetingNotes

    /// Google voice keycaps, injected from the live hotkey config by the
    /// production flow so the Google tab shows the real chord.
    let googleChord: [KeycapContent]

    private static let amber = Color(red: 0.91, green: 0.57, blue: 0.24)
    private static let stopOrange = Color(red: 1.0, green: 0.49, blue: 0.23)
    private static let green = Color(red: 0.31, green: 0.78, blue: 0.51)

    init(
        onBack: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        googleChord: [KeycapContent] = [.text("R\u{2009}\u{2325}")]
    ) {
        self.onBack = onBack
        self.onContinue = onContinue
        self.googleChord = googleChord
    }

    enum Feature: CaseIterable {
        case meetingNotes, google, other
    }

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .frame(width: OnboardingTheme.leftPaneWidth, alignment: .topLeading)
                .background(OnboardingTheme.bg)
                .overlay(
                    Rectangle().fill(OnboardingTheme.border).frame(width: 0.5),
                    alignment: .trailing
                )
            demoPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                Text("Helpers.")
                    .font(OnboardingTheme.serifItalic(42))
                    .foregroundColor(OnboardingTheme.ink)
                    .kerning(-0.6)
                Text("Whytap does more than dictate — meeting notes, instant Google, and a hover panel of tools.")
                    .font(OnboardingTheme.sans(13.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                FeatureCard(
                    symbol: "note.text",
                    tile: Color(red: 0.91, green: 0.57, blue: 0.24),
                    title: "Meeting Notes",
                    subtitle: "Tasks · Decisions · Summary",
                    selected: feature == .meetingNotes,
                    action: { withAnimation(.easeInOut(duration: 0.18)) { feature = .meetingNotes } }
                )
                FeatureCard(
                    symbol: "magnifyingglass",
                    tile: Color(red: 0.259, green: 0.522, blue: 0.957),
                    title: "Google",
                    subtitle: "Hold R⌥, ask, get results",
                    selected: feature == .google,
                    action: { withAnimation(.easeInOut(duration: 0.18)) { feature = .google } }
                )
                FeatureCard(
                    symbol: "square.grid.2x2.fill",
                    tile: Color(red: 0.55, green: 0.36, blue: 1.0),
                    title: "Other",
                    subtitle: "Case, Filler, History & more",
                    selected: feature == .other,
                    action: { withAnimation(.easeInOut(duration: 0.18)) { feature = .other } }
                )
            }
            .padding(.top, 22)

            Spacer(minLength: 0)

            footer
        }
        .padding(EdgeInsets(top: 40, leading: 36, bottom: 22, trailing: 28))
    }

    // MARK: - Demo pane

    @ViewBuilder
    private var demoPane: some View {
        switch feature {
        case .meetingNotes:
            ZStack(alignment: .top) {
                HelpersBackdrop()
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        menuBarIsland

                        ZStack {
                            switch stage {
                            case 0: attachedNudge
                            case 1: recordingStage
                            default: notesStage
                            }
                        }
                        .padding(.top, stage == 0 ? 0 : 22)
                    }
                    .padding(.top, 24)

                    caption
                        .padding(.top, 16)
                }
                .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await runLoop() }

        case .google:
            ZStack {
                GoogleBackdrop()
                VStack(spacing: 16) {
                    GoogleVoiceHint(chord: googleChord)
                    GoogleSearchMock(query: "best ramen places in Tokyo")
                }
                .frame(maxWidth: 430)
                .padding(32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .other:
            otherDemo
        }
    }

    // MARK: - Other demo (hover tools grid)

    private var otherDemo: some View {
        ZStack {
            OtherBackdrop()
            HoverToolsMock()
                .frame(maxWidth: 440)
                .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Back")
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(OnboardingTheme.muted)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: onContinue) {
                HStack(spacing: 6) {
                    Text("Continue")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(OnboardingTheme.bg)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .fixedSize(horizontal: true, vertical: false)
                .background(Capsule(style: .continuous).fill(OnboardingTheme.ink))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Right pane (staged animation) — Meeting Notes

    private var menuBarIsland: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.5))
                .frame(width: 430, height: 24)
            HStack(spacing: 7) {
                // Calm idle "silent ring" — the menu-bar island is quiet while
                // the Meeting Notes flow plays below; a lit orb here flashes.
                // The ring draws at a fixed 25pt, so scale it down for the notch.
                VoiceOrbView(mode: .idle, levels: [0], isDarkBackground: true)
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
                Text("Whytap")
                    .font(OnboardingTheme.mono(8, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(.white.opacity(0.55))
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            // Widened to the nudge's width, flat bottom edge so it glues
            // seamlessly to the attached Take-notes / Skip button below.
            .frame(width: 230, height: 30)
            .background(Rectangle().fill(Color.black))
        }
    }

    // Stage 0 — the take-notes nudge, glued directly under the island the way
    // the real meeting nudge hangs off the Dynamic Island. Sized between the
    // notch and a full-width button. Auto-plays the prod choice: the nudge
    // appears, then "Take notes" is selected — its half grows to full width and
    // Skip fades out (mirrors `MeetingNudgeView`'s hover behaviour).
    private var attachedNudge: some View {
        let totalWidth: CGFloat = 230
        let lightWidth: CGFloat = nudgeChosen ? totalWidth : totalWidth * 0.6
        let darkWidth: CGFloat = totalWidth - lightWidth
        return VStack(spacing: 7) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Take notes")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(Color(red: 0.04, green: 0.04, blue: 0.04))
                .frame(width: lightWidth)
                .frame(maxHeight: .infinity)
                .background(Color.white)
                .scaleEffect(nudgePress ? 0.965 : 1)

                Text("Skip")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: darkWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color(red: 0.04, green: 0.04, blue: 0.04))
                    .opacity(nudgeChosen ? 0 : 1)
            }
            .frame(width: totalWidth, height: 30)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 13,
                    bottomTrailingRadius: 13, topTrailingRadius: 0, style: .continuous
                )
            )
            .shadow(color: .black.opacity(0.45), radius: 13, y: 8)

            // Draining 20s countdown bar — gone once the choice is committed.
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: totalWidth, height: 2)
                Capsule().fill(Self.amber.opacity(0.85)).frame(width: totalWidth * nudgeDrain, height: 2)
            }
            .opacity(nudgeChosen ? 0 : 1)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // Stage 1 — recording pill
    private var recordingStage: some View {
        VStack(spacing: 0) {
            Text("Whytap meeting notes")
                .font(OnboardingTheme.sans(11))
                .foregroundColor(OnboardingTheme.ink2)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(OnboardingTheme.surface2)
                .overlay(Rectangle().fill(OnboardingTheme.border).frame(height: 0.5), alignment: .bottom)

            VStack(spacing: 10) {
                TimelineView(.periodic(from: recordingStart, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(recordingStart)))
                    Text(timeString(42 + elapsed))
                        .font(.system(size: 30, weight: .light, design: .monospaced))
                        .kerning(-0.8)
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                }
                RecordingWaveform()
                    .frame(width: 230, height: 40)
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 34, height: 34)
                        .overlay(
                            Image(systemName: "pause.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                        )
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 34, height: 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Self.stopOrange)
                                .frame(width: 11, height: 11)
                                .shadow(color: Self.stopOrange.opacity(0.7), radius: 8)
                        )
                }
            }
            .padding(.vertical, 14)
            .background(Color(red: 0.055, green: 0.055, blue: 0.07))
        }
        .frame(width: 300)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .onAppear { recordingStart = Date() }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // Stage 2 — written notes
    private var notesStage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(OnboardingTheme.trafficRed).frame(width: 7, height: 7)
                Circle().fill(OnboardingTheme.trafficYellow).frame(width: 7, height: 7)
                Circle().fill(OnboardingTheme.trafficGreen).frame(width: 7, height: 7)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(OnboardingTheme.surface2)

            VStack(alignment: .leading, spacing: 0) {
                Text("Design Sync")
                    .font(OnboardingTheme.serif(18))
                    .foregroundColor(OnboardingTheme.ink)
                Text("Today · 24 min · 3 speakers")
                    .font(OnboardingTheme.sans(11))
                    .foregroundColor(OnboardingTheme.muted)
                    .padding(.top, 2)

                sectionLabel("TASKS").padding(.top, 11)
                taskRow("Ship the new island layout", who: "Anna", when: "Fri")
                taskRow("Draft the pricing doc", who: "Max", when: nil)

                trackerExportRow.padding(.top, 9)

                sectionLabel("DECISIONS").padding(.top, 11)
                HStack(alignment: .top, spacing: 7) {
                    Text("•").font(OnboardingTheme.sans(11)).foregroundColor(OnboardingTheme.muted)
                    Text("Go with Soniox first, Deepgram fallback.")
                        .font(OnboardingTheme.sans(11.5))
                        .foregroundColor(OnboardingTheme.ink2)
                }
                .padding(.top, 5)
            }
            .padding(EdgeInsets(top: 13, leading: 16, bottom: 15, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OnboardingTheme.surface)
        }
        .frame(width: 330)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(OnboardingTheme.mono(9, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(OnboardingTheme.accent)
    }

    private func taskRow(_ text: String, who: String, when: String?) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "square")
                .font(.system(size: 11))
                .foregroundColor(OnboardingTheme.muted)
                .padding(.top, 1)
            (
                Text(text + " — ").font(OnboardingTheme.sans(11.5)).foregroundColor(OnboardingTheme.ink2)
                + Text(who).font(OnboardingTheme.sans(11.5, weight: .medium)).foregroundColor(OnboardingTheme.ink)
                + Text(when.map { " · \($0)" } ?? "").font(OnboardingTheme.sans(11.5)).foregroundColor(OnboardingTheme.muted)
            )
        }
        .padding(.top, 5)
    }

    /// Shows that a meeting task can be pushed straight into a tracker —
    /// one tap turns it into an issue in Linear or Asana from the note.
    private var trackerExportRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(OnboardingTheme.muted)
            Text("Send to")
                .font(OnboardingTheme.sans(11))
                .foregroundColor(OnboardingTheme.muted)
            trackerChip(appIcon: "linear", name: "Linear", tint: Color(red: 0.36, green: 0.36, blue: 0.96))
            trackerChip(appIcon: "asana", name: "Asana", tint: Color(red: 0.95, green: 0.36, blue: 0.42))
            Spacer(minLength: 0)
        }
    }

    private func trackerChip(appIcon: String, name: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Group {
                if let image = onboardingAppIcon(appIcon) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint)
                }
            }
            .frame(width: 13, height: 13)
            Text(name)
                .font(OnboardingTheme.sans(10.5, weight: .medium))
                .foregroundColor(OnboardingTheme.ink2)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().stroke(OnboardingTheme.border, lineWidth: 0.5))
    }

    private var caption: some View {
        Text(captionText)
            .font(OnboardingTheme.serifItalic(15))
            .foregroundColor(OnboardingTheme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .contentTransition(.opacity)
    }

    private var captionText: String {
        switch stage {
        case 0: return nudgeChosen
            ? "You picked Take notes — recording starts."
            : "Whytap notices you're in a meeting…"
        case 1: return "It records the room — mic + system audio."
        default: return "…writes the notes — then push any task to Linear or Asana."
        }
    }

    // MARK: - Timeline

    private func runLoop() async {
        while !Task.isCancelled {
            // Stage 0 — the nudge appears, then auto-chooses "Take notes".
            withAnimation(.easeInOut(duration: 0.3)) {
                stage = 0
                nudgeChosen = false
                nudgePress = false
            }
            nudgeDrain = 1
            withAnimation(.linear(duration: 2.8)) { nudgeDrain = 0.5 }
            await sleep(2.6)
            guard !Task.isCancelled else { return }

            // Press, then commit: the light half fills and Skip fades out.
            withAnimation(.easeInOut(duration: 0.12)) { nudgePress = true }
            await sleep(0.15)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                nudgeChosen = true
                nudgePress = false
            }
            await sleep(1.8)
            guard !Task.isCancelled else { return }

            // Stage 1 — recording the room.
            withAnimation(.easeInOut(duration: 0.5)) { stage = 1 }
            await sleep(4.4)
            guard !Task.isCancelled else { return }

            // Stage 2 — the written notes.
            withAnimation(.easeInOut(duration: 0.5)) { stage = 2 }
            await sleep(4.8)
            guard !Task.isCancelled else { return }
        }
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Feature card

private struct FeatureCard: View {
    let symbol: String
    let tile: Color
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tile)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(OnboardingTheme.sans(13.5, weight: .medium))
                        .foregroundColor(OnboardingTheme.ink)
                    Text(subtitle)
                        .font(OnboardingTheme.sans(11.5))
                        .foregroundColor(OnboardingTheme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? OnboardingTheme.surface2 : OnboardingTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        selected ? OnboardingTheme.accent.opacity(0.55) : OnboardingTheme.border,
                        lineWidth: selected ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hover tools mock (Other demo)

private struct HoverToolsMock: View {
    /// Hardcoded snapshot of hover tools (excluding settings/quit/notes) so
    /// this mock has zero import dependencies on the main Sidekey target types.
    private struct ToolEntry: Identifiable {
        let id: String
        let sfSymbol: String
        let title: String
        let description: String
    }

    private let tools: [ToolEntry] = [
        ToolEntry(id: "dropMode",   sfSymbol: "bolt",                title: "Drop Mode",   description: "Switch between Fast and Smart transcription"),
        ToolEntry(id: "notifs",     sfSymbol: "bell",                title: "Notifs",      description: "View recent notification history"),
        ToolEntry(id: "clipboard",  sfSymbol: "clock.arrow.circlepath", title: "History", description: "Open unified history"),
        ToolEntry(id: "vocab",      sfSymbol: "book",                title: "Vocab",       description: "Manage vocabulary and custom terms"),
        ToolEntry(id: "caseVault",  sfSymbol: "key.horizontal",      title: "Case",        description: "Store and reuse text snippets"),
        ToolEntry(id: "filler",     sfSymbol: "scissors",            title: "Filler",      description: "Fill in common phrases"),
        ToolEntry(id: "inputLang",  sfSymbol: "globe",               title: "Input Lang",  description: "Choose input language for transcription"),
        ToolEntry(id: "outputLang", sfSymbol: "globe",               title: "Output Lang", description: "Choose output language for Smart Mode translation"),
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Faux titlebar
            HStack(spacing: 6) {
                Circle().fill(OnboardingTheme.trafficRed).frame(width: 9, height: 9)
                Circle().fill(OnboardingTheme.trafficYellow).frame(width: 9, height: 9)
                Circle().fill(OnboardingTheme.trafficGreen).frame(width: 9, height: 9)
                Text("Hover tools")
                    .font(OnboardingTheme.mono(10, weight: .medium))
                    .foregroundColor(OnboardingTheme.faint)
                    .padding(.leading, 8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(OnboardingTheme.surface2)
            .overlay(Rectangle().fill(OnboardingTheme.border).frame(height: 0.5), alignment: .bottom)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(OnboardingTheme.surface2)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Image(systemName: tool.sfSymbol)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(OnboardingTheme.ink2)
                            )
                        Text(tool.title)
                            .font(OnboardingTheme.sans(12.5, weight: .medium))
                            .foregroundColor(OnboardingTheme.ink)
                        Text(tool.description)
                            .font(OnboardingTheme.sans(10.5))
                            .foregroundColor(OnboardingTheme.muted)
                            .lineLimit(2)
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(OnboardingTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OnboardingTheme.border, lineWidth: 0.5)
                    )
                }
            }
            .padding(12)
            .background(OnboardingTheme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 26, x: 0, y: 16)
    }
}

// MARK: - Live waveform (synthetic, TimelineView-driven)

private struct RecordingWaveform: View {
    private let count = 44

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: barHeight(i: i, t: t))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.04),
                        .init(color: .black, location: 0.96),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
        }
    }

    private func barHeight(i: Int, t: Double) -> CGFloat {
        let phase = Double(i) * 0.42
        let slow = (sin(t * 3.1 + phase) + 1) * 0.5
        let fast = (sin(t * 9.0 + phase * 1.7) + 1) * 0.5
        let level = slow * 0.7 + fast * 0.3
        return 4 + CGFloat(level) * 32
    }
}

// MARK: - Backdrop (warm meeting-notes wash)

private struct HelpersBackdrop: View {
    var body: some View {
        OnboardingTheme.surface2
            .overlay(
                ZStack {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 0.91, green: 0.57, blue: 0.24).opacity(0.16), location: 0),
                            .init(color: .clear, location: 0.55)
                        ]),
                        center: UnitPoint(x: 0.5, y: 0.0),
                        startRadius: 0, endRadius: 560
                    )
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 1.0, green: 0.49, blue: 0.23).opacity(0.12), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.12, y: 1.0),
                        startRadius: 0, endRadius: 520
                    )
                }
            )
    }
}

// MARK: - Shared step row (kept for potential reuse)

private struct HelperStepRow: View {
    let n: Int
    let label: String
    let desc: String
    let chord: [KeycapContent]?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(String(format: "%02d", n))
                .font(OnboardingTheme.mono(10.5))
                .tracking(0.6)
                .foregroundColor(OnboardingTheme.faint)
                .frame(width: 18, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text("\(label).")
                        .font(OnboardingTheme.serifItalic(20))
                        .foregroundColor(OnboardingTheme.ink)
                    if let chord {
                        HStack(spacing: 4) {
                            ForEach(Array(chord.enumerated()), id: \.offset) { _, content in
                                HelperKeycap(content: content)
                            }
                        }
                    }
                }
                Text(desc)
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HelperKeycap: View {
    let content: KeycapContent

    var body: some View {
        Group {
            switch content {
            case .text(let value):
                Text(value).font(.system(size: 12, weight: .semibold))
            case .symbol(let name, _):
                Image(systemName: name).font(.system(size: 10, weight: .semibold))
            case .prefixedGlyph(let prefix, let glyph, _):
                HStack(spacing: 3) {
                    Text(prefix).font(.system(size: 8, weight: .medium)).opacity(0.85)
                    Text(glyph).font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .foregroundColor(OnboardingTheme.ink)
        .frame(minWidth: 22, minHeight: 22)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(OnboardingTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(OnboardingTheme.borderStrong, lineWidth: 0.5))
    }
}

// MARK: - Google voice hint (R⌥ keycap above the search mock)

private struct GoogleVoiceHint: View {
    let chord: [KeycapContent]

    private static let blue = Color(red: 0.259, green: 0.522, blue: 0.957)

    var body: some View {
        HStack(spacing: 8) {
            Text("Hold")
                .font(OnboardingTheme.sans(12.5, weight: .medium))
                .foregroundColor(OnboardingTheme.ink2)
            HStack(spacing: 4) {
                ForEach(Array(chord.enumerated()), id: \.offset) { _, content in
                    HelperKeycap(content: content)
                }
            }
            Text("and ask — Whytap googles it and opens the answer.")
                .font(OnboardingTheme.sans(12.5))
                .foregroundColor(OnboardingTheme.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule(style: .continuous).fill(Self.blue.opacity(0.10)))
        .overlay(Capsule(style: .continuous).stroke(Self.blue.opacity(0.35), lineWidth: 0.75))
    }
}

// MARK: - Google search mock (right pane of the Google feature)

private struct GoogleSearchMock: View {
    let query: String

    private static let blue = Color(red: 0.259, green: 0.522, blue: 0.957)
    private static let red = Color(red: 0.918, green: 0.263, blue: 0.208)
    private static let yellow = Color(red: 0.984, green: 0.737, blue: 0.020)
    private static let green = Color(red: 0.204, green: 0.659, blue: 0.325)

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            VStack(spacing: 14) {
                googleWordmark
                searchPill
                VStack(alignment: .leading, spacing: 13) {
                    resultRow(
                        title: "The 11 best ramen shops in Tokyo",
                        url: "timeout.com › tokyo › restaurants",
                        snippet: "From rich tonkotsu to delicate shio — the bowls locals queue for."
                    )
                    resultRow(
                        title: "Tokyo ramen guide: where to slurp",
                        url: "ramenbeast.com › tokyo",
                        snippet: "A curated map of the city's standout shops, by neighbourhood."
                    )
                }
            }
            .padding(EdgeInsets(top: 18, leading: 18, bottom: 20, trailing: 18))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OnboardingTheme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.40), radius: 30, x: 0, y: 20)
        .shadow(color: .black.opacity(0.20), radius: 8, x: 0, y: 4)
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            Circle().fill(OnboardingTheme.trafficRed).frame(width: 9, height: 9)
            Circle().fill(OnboardingTheme.trafficYellow).frame(width: 9, height: 9)
            Circle().fill(OnboardingTheme.trafficGreen).frame(width: 9, height: 9)
            Text("google.com/search")
                .font(OnboardingTheme.mono(9.5))
                .foregroundColor(OnboardingTheme.faint)
                .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(OnboardingTheme.surface2)
        .overlay(Rectangle().fill(OnboardingTheme.border).frame(height: 0.5), alignment: .bottom)
    }

    private var googleWordmark: some View {
        HStack(spacing: 0) {
            letter("G", Self.blue)
            letter("o", Self.red)
            letter("o", Self.yellow)
            letter("g", Self.blue)
            letter("l", Self.green)
            letter("e", Self.red)
        }
    }

    private func letter(_ ch: String, _ color: Color) -> some View {
        Text(ch)
            .font(.system(size: 26, weight: .medium, design: .rounded))
            .foregroundColor(color)
    }

    private var searchPill: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(OnboardingTheme.muted)
            Text(query)
                .font(OnboardingTheme.sans(13))
                .foregroundColor(OnboardingTheme.ink)
            Spacer(minLength: 0)
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Self.blue)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Capsule(style: .continuous).fill(OnboardingTheme.surface2))
        .overlay(Capsule(style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
    }

    private func resultRow(title: String, url: String, snippet: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(url)
                .font(OnboardingTheme.sans(10.5))
                .foregroundColor(OnboardingTheme.faint)
            Text(title)
                .font(OnboardingTheme.sans(14, weight: .medium))
                .foregroundColor(Self.blue)
            Text(snippet)
                .font(OnboardingTheme.sans(11.5))
                .foregroundColor(OnboardingTheme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct GoogleBackdrop: View {
    var body: some View {
        OnboardingTheme.surface2
            .overlay(
                ZStack {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 0.259, green: 0.522, blue: 0.957).opacity(0.16), location: 0),
                            .init(color: .clear, location: 0.55)
                        ]),
                        center: UnitPoint(x: 0.5, y: 0.0),
                        startRadius: 0, endRadius: 560
                    )
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 0.204, green: 0.659, blue: 0.325).opacity(0.12), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.12, y: 1.0),
                        startRadius: 0, endRadius: 520
                    )
                }
            )
    }
}

private struct OtherBackdrop: View {
    var body: some View {
        OnboardingTheme.surface2
            .overlay(
                ZStack {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: OnboardingTheme.accent.opacity(0.16), location: 0),
                            .init(color: .clear, location: 0.55)
                        ]),
                        center: UnitPoint(x: 0.5, y: 0.0),
                        startRadius: 0, endRadius: 560
                    )
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 0.55, green: 0.36, blue: 1.0).opacity(0.12), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.12, y: 1.0),
                        startRadius: 0, endRadius: 520
                    )
                }
            )
    }
}
