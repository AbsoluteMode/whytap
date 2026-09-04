import SwiftUI

/// SwiftUI body for the recording / paused pill state. Visual target:
/// `docs/design/meeting-pill-prototype.swift` (RecordingCard).
///
/// **Production adaptations from the prototype** (per the prototype's
/// header instructions):
///
/// - Real audio levels: `audioLevel` is fed by `MeetingRecorder.audioLevelStream`
///   via the coordinator → controller → `updateLiveState(audioLevel:duration:)`.
///   The waveform pushes the latest level into a rolling buffer of length
///   `Waveform.barCount` so each bar maps to a recent moment in time
///   (newest on the right).
/// - Real timer: `duration` is fed by `MeetingRecorder.durationStream`.
///   `TimerLabel` formats `MM:SS` with monospaced digits.
/// - Pause / Play action calls `onPauseToggle`, which the parent maps to
///   `controller.pause()` or `controller.resume()` depending on the
///   current state — emits `MeetingPillEvent.pause` / `.resume` so the
///   coordinator can call `recorder.pause()` / `recorder.resume()`.
/// - Stop action calls `onStop`, mapped to `controller.stopRecording()`
///   which emits `MeetingPillEvent.stop`.
///
/// **Paused state visual:** the prototype only renders one card style and
/// flips the play/pause glyph; we follow that, plus dim the waveform
/// (audioLevel forced to 0 in `MeetingRecorder.pause()` so the rolling
/// buffer naturally drains to flat bars) and surface an inline "Paused"
/// affordance for screen readers.
struct MeetingRecordingPillView: View {
    let audioLevel: Double
    let duration: TimeInterval
    let isPaused: Bool
    let onPauseToggle: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Attached "Whytap meeting notes" tab. Sits flush with the
            // top of the card, slightly offset right so it reads as a
            // tab attached to the recording surface.
            HStack {
                Text("Whytap meeting notes")
                    .font(.system(size: 13))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 12
                )
                .fill(LinearGradient(
                    colors: [Color(white: 0.11), Color(white: 0.08)],
                    startPoint: .top, endPoint: .bottom
                ))
            )
            .padding(.leading, 18)
            .offset(y: 10)
            .accessibilityHidden(true)

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    TimerLabel(elapsed: duration)
                    Waveform(audioLevel: audioLevel, isPaused: isPaused)
                        .frame(height: 90)
                }
                VStack(spacing: 8) {
                    IconButton(systemName: isPaused ? "play.fill" : "pause.fill", action: onPauseToggle)
                        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
                    StopButton(action: onStop)
                        .accessibilityLabel("Stop recording")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .frame(width: 640)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isPaused ? "Recording paused" : "Recording in progress")
    }
}

// MARK: - TimerLabel

private struct TimerLabel: View {
    let elapsed: TimeInterval

    var body: some View {
        let total = Int(elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let text: String
        if hours > 0 {
            text = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            text = String(format: "%02d:%02d", minutes, seconds)
        }
        return Text(text)
            .font(.system(size: 40, weight: .light, design: .monospaced))
            .kerning(-0.8)
            .foregroundStyle(.white)
            .monospacedDigit()
            .accessibilityLabel("Elapsed time \(text)")
    }
}

// MARK: - Waveform

/// 220-bar audio-reactive waveform driven by real `audioLevel` updates.
/// The prototype uses mock sine math; we replace that with a per-bar
/// rolling buffer fed by the audio-level stream. Each `audioLevel`
/// update is pushed into the buffer (newest at the rightmost bar);
/// older bars decay slightly so the visual breathes even when the
/// level is steady.
///
/// Bar count + edge fade mask preserved from the prototype.
private struct Waveform: View {
    let audioLevel: Double
    let isPaused: Bool

    static let barCount: Int = 220
    private let barWidth: CGFloat = 1.5
    private let barGap: CGFloat = 1.5

    /// Per-instance rolling buffer. Keyed by `audioLevel` via
    /// `onChange` so the buffer rotates exactly once per upstream
    /// update; `phases` adds a static per-bar jitter so the bars do not
    /// look perfectly mirrored.
    @SwiftUI.State private var levels: [Double] = Array(repeating: 0, count: Waveform.barCount)
    @SwiftUI.State private var phases: [Double] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: barGap) {
                    ForEach(0..<Self.barCount, id: \.self) { i in
                        let normalizedPos = Double(i) / Double(Self.barCount - 1)
                        let edge = sin(.pi * normalizedPos)
                        let level = levels.indices.contains(i) ? levels[i] : 0
                        let phase = phases.indices.contains(i) ? phases[i] : 0
                        let jitter = isPaused
                            ? 0.4
                            : (sin(t * 14 + phase) * 0.5 + 0.5) * 0.35 + 0.65
                        let h = max(3, level * edge * jitter * 0.85 * Double(geo.size.height))
                        Capsule()
                            .fill(.white.opacity(isPaused ? 0.35 : 0.85))
                            .frame(width: barWidth, height: CGFloat(h))
                    }
                }
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.03),
                        .init(color: .black, location: 0.97),
                        .init(color: .clear, location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                )
            }
        }
        .onAppear {
            if phases.isEmpty {
                phases = (0..<Self.barCount).map { _ in Double.random(in: 0..<(2 * Double.pi)) }
            }
        }
        .onChange(of: audioLevel) { newLevel in
            // Shift left; append newest at the right. Apply a soft
            // baseline so even very quiet input shows some life.
            var next = Array(levels.dropFirst())
            let baseline = 0.05
            next.append(max(baseline, newLevel))
            levels = next
        }
        .accessibilityHidden(true)
    }
}

// MARK: - IconButton

private struct IconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 38, height: 38)
                .background(
                    .white.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 10)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - StopButton

private struct StopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color(red: 1, green: 0.49, blue: 0.23))
                .frame(width: 11, height: 11)
                .shadow(color: Color(red: 1, green: 0.49, blue: 0.23).opacity(0.55), radius: 4)
                .frame(width: 38, height: 38)
                .background(
                    LinearGradient(
                        colors: [.white, Color(white: 0.92)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 10)
                )
        }
        .buttonStyle(.plain)
    }
}
