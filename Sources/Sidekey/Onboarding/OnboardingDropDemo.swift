import SwiftUI

/// Plays Drop on the first page: the key goes down, the real island orb
/// listens, thinks, and the sentence lands in a pictured note. Scripted and
/// silent; it needs no microphone, permission or model, and stops when the
/// page goes away. With Reduce Motion the note simply shows the result.
@MainActor
final class OnboardingDropDemo: ObservableObject {
    enum Phase: Equatable { case idle, recording, thinking, done }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0

    static let sentence = "Moving our sync to Thursday at 3. I'll send the new invite tonight."

    private var task: Task<Void, Never>?

    func start(reduceMotion: Bool) {
        guard task == nil else { return }
        guard !reduceMotion else {
            phase = .done
            return
        }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // A freed demo ends the loop instead of spinning.
                guard let self else { return }
                await self.cycle()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        phase = .idle
        level = 0
    }

    /// One fixed moment, for offscreen review images.
    func show(_ phase: Phase, level: Float = 0.6) {
        stop()
        self.phase = phase
        self.level = level
    }

    private func cycle() async {
        phase = .idle
        level = 0
        await sleep(1.4)
        // A stopped demo must not write over the phase it was stopped at.
        guard !Task.isCancelled else { return }
        phase = .recording
        let start = Date()
        while !Task.isCancelled, Date().timeIntervalSince(start) < 2.6 {
            let t = Date().timeIntervalSince(start)
            let breath = (sin(t * 1.8) + 1) * 0.5
            let burst = sin(t * 7.5 + 1.2) * 0.18
            level = Float(max(0.18, min(0.95, breath * 0.7 + burst + 0.18)))
            await sleep(0.03)
        }
        guard !Task.isCancelled else { return }
        level = 0
        phase = .thinking
        await sleep(1.2)
        guard !Task.isCancelled else { return }
        phase = .done
        await sleep(3.2)
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// The stage of the first page: a note, the island orb and one line saying
/// where the words appear while you speak.
struct OnboardingDropDemoStage: View {
    @ObservedObject var demo: OnboardingDropDemo
    let chord: [KeycapContent]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 26) {
            OnboardingMockWindow(caption: "NOTES — UNTITLED") {
                OnboardingKeycaps(contents: chord, held: demo.phase == .recording)
            } content: {
                noteText
                    .padding(18)
                    .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            }
            VoiceOrbView(mode: orbMode, levels: [demo.level], isDarkBackground: true)
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Capsule(style: .continuous)
                    .fill(Color.black)
                    .frame(width: 46, height: 15)
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(OnboardingTheme.accent.opacity(0.5), lineWidth: 0.75))
                    .overlay(Circle().fill(OnboardingTheme.accent.opacity(0.85)).frame(width: 7, height: 7))
                Text("Your words show in the island while you speak.")
                    .font(OnboardingTheme.sans(12))
                    .foregroundColor(OnboardingTheme.muted)
            }
        }
        .frame(maxWidth: 440)
        .onAppear { demo.start(reduceMotion: reduceMotion) }
        .onDisappear { demo.stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: a sentence spoken with Drop appears in a note.")
    }

    @ViewBuilder private var noteText: some View {
        switch demo.phase {
        case .idle:
            Text("Click a text field, then hold the key and speak…")
                .font(OnboardingTheme.serifItalic(17))
                .foregroundColor(OnboardingTheme.faint)
        case .recording:
            Text("listening…")
                .font(OnboardingTheme.serifItalic(17))
                .foregroundColor(OnboardingTheme.faint)
        case .thinking:
            Text("typing…")
                .font(OnboardingTheme.serifItalic(17))
                .foregroundColor(OnboardingTheme.faint)
        case .done:
            Text(OnboardingDropDemo.sentence)
                .font(OnboardingTheme.serif(19))
                .foregroundColor(OnboardingTheme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }

    private var orbMode: VoiceOrbMode {
        switch demo.phase {
        case .recording: return .dropVoice
        case .thinking: return .dropProcessing
        case .idle, .done: return .idle
        }
    }
}
