import SwiftUI

enum WaveformMode {
    /// RMS-driven from `AppState.audioLevels`, with sin/cos perturbation for life.
    case recording
    /// Pure decorative sin/cos animation; `levels` is ignored.
    case processing
}

/// Symmetric, gaussian-tapered bar visualisation matching ElevenLabs'
/// `LiveWaveform` reference. Renders 22 capsules side-by-side, animated at
/// roughly 30 fps via `TimelineView(.animation)`.
struct WaveformBars: View {
    let mode: WaveformMode
    let levels: [Float]
    /// Pause the per-frame animation when the bars are not actively
    /// shown (e.g. recording panel is hidden). When paused TimelineView
    /// stops ticking and the SwiftUI animation pipeline does no work —
    /// matches the rest of the orb stack's idle-frame discipline.
    var paused: Bool = false

    private let barCount: Int = 22
    private let barWidth: CGFloat = 2
    private let barGap: CGFloat = 1
    private let maxBarHeight: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { ctx in
            let now = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: barGap) {
                ForEach(0..<barCount, id: \.self) { i in
                    let h = WaveformBars.barHeight(
                        index: i,
                        barCount: barCount,
                        time: now,
                        mode: mode,
                        levels: levels,
                        maxBarHeight: maxBarHeight
                    )
                    let opacity = WaveformBars.barOpacity(
                        index: i,
                        barCount: barCount,
                        normalizedHeight: h / maxBarHeight
                    )
                    Capsule()
                        .fill(Color.white.opacity(opacity))
                        .frame(width: barWidth, height: max(2, h))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    /// Pure-logic — testable.
    /// Returns a bar height in points, gaussian-tapered around the centre and
    /// modulated by either RMS (recording) or decorative sin/cos (processing).
    static func barHeight(
        index: Int,
        barCount: Int,
        time: Double,
        mode: WaveformMode,
        levels: [Float],
        maxBarHeight: CGFloat
    ) -> CGFloat {
        let half = Double(barCount) / 2
        let normalizedPos = (Double(index) - half) / half
        let centerWeight = 1.0 - abs(normalizedPos) * 0.4

        let wave1 = sin(time * 1.5 + normalizedPos * 3) * 0.25
        let wave2 = sin(time * 0.8 - normalizedPos * 2) * 0.20
        let wave3 = cos(time * 2.0 + normalizedPos) * 0.15
        let combined = wave1 + wave2 + wave3

        let baseEnergy: Double
        switch mode {
        case .recording:
            if levels.isEmpty {
                baseEnergy = 0.0
            } else {
                let recent = levels.suffix(8)
                baseEnergy = Double(recent.reduce(0, +)) / Double(recent.count)
            }
        case .processing:
            baseEnergy = 0.2
        }

        let value = max(0.05, min(1.0, (baseEnergy + combined) * centerWeight))
        return CGFloat(value) * maxBarHeight
    }

    /// Pure-logic — testable. Reference: `0.4 + value * 0.6`.
    static func barOpacity(
        index: Int,
        barCount: Int,
        normalizedHeight: CGFloat
    ) -> Double {
        let v = Double(max(0, min(1, normalizedHeight)))
        return 0.4 + v * 0.6
    }
}
