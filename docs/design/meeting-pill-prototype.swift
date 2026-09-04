// Meeting Notes pill UI prototype — design reference for Stage 4.
//
// Status: NOT production code. This file is a design specimen, not compiled
// into Sidekey. It establishes the visual language for the meeting detection
// pill (suggesting state) and recording state UI. Stage 4 production
// implementation must:
//
//   1. Replace local `@State` machine with binding to the existing
//      `MeetingPillController` event stream from Stage 3 (state machine
//      owns transitions, view observes).
//   2. Replace mock TimelineView sine-wave waveform with real audio levels
//      from `MeetingRecorder.audioLevelStream` (Stage 4 wiring).
//   3. Replace local Button actions with `pill.events`:
//      - "Yes, record" → emit `.accept(meetingId)`
//      - "No, skip" / drain expiry → emit `.dismiss(reason: .user | .timeout)`
//      - Stop button → emit `.stop`
//   4. **Honor `MeetingsConfig.pillDecisionTimeoutSeconds = 30`** for the
//      drain animation cycle — prototype uses 15 for visual testing, but the
//      spec/plan pin 30s and Stage 3 production code already follows that.
//   5. Apply ambient warm background to both suggesting AND recording NSPanel
//      hosts (top-center, .statusBar level — geometry already established
//      by `MeetingPillPanel` in Stage 3).
//   6. English copy only (per 2026-05-19 decision); retroactively replace the
//      Russian "Запиши встречу?" Stage 3 shipped with the prototype's
//      "Record this meeting?" wording.
//   7. Pause button is new vs the original spec — keep it; it's a real UX
//      improvement during long meetings (smoke-tests / coffee / interruptions).

import SwiftUI

// MARK: - Root

struct EchoCaptureView: View {
    enum State { case detected, recording, dismissed }
    @SwiftUI.State private var state: State = .detected

    var body: some View {
        ZStack {
            AmbientBackground()

            switch state {
            case .detected:
                DetectedCard(
                    onYes: { withAnimation(.easeInOut(duration: 0.35)) { state = .recording } },
                    onNo:  { withAnimation(.easeInOut(duration: 0.35)) { state = .dismissed } }
                )
                .transition(.scale(scale: 0.99).combined(with: .opacity))

            case .recording:
                RecordingCard(
                    onStop: { withAnimation(.easeInOut(duration: 0.35)) { state = .dismissed } }
                )
                .transition(.move(edge: .top).combined(with: .opacity))

            case .dismissed:
                Button("Bring back") { state = .detected }
                    .foregroundStyle(.secondary)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Ambient warm background

struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.03, blue: 0.03)
            RadialGradient(
                colors: [Color(red: 1, green: 0.43, blue: 0.20).opacity(0.28), .clear],
                center: .bottom, startRadius: 0, endRadius: 600
            )
            RadialGradient(
                colors: [Color(red: 1, green: 0.55, blue: 0.31).opacity(0.08), .clear],
                center: .center, startRadius: 0, endRadius: 500
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Detected (Record this meeting?)

struct DetectedCard: View {
    let onYes: () -> Void
    let onNo:  () -> Void
    // PROTOTYPE: 15s — PRODUCTION MUST USE MeetingsConfig.pillDecisionTimeoutSeconds = 30
    private let cycle: Double = 15

    @SwiftUI.State private var drainProgress: CGFloat = 1   // 1 → 0 over `cycle`

    var body: some View {
        HStack(spacing: 10) {
            Text("Record this meeting?")
                .font(.system(size: 15.5, weight: .medium))
                .kerning(-0.2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onYes) {
                Text("Yes, record")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(
                        LinearGradient(colors: [.white, Color(white: 0.92)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
            Button(action: onNo) {
                Text("No, skip")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(width: 640)
        .background(alignment: .center) {
            // faint static outline (always visible)
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.18), lineWidth: 1)
            // bright drain — draws fully then trims away
            RoundedRectangle(cornerRadius: 18)
                .trim(from: 0, to: drainProgress)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .shadow(color: Color(red: 1, green: 0.88, blue: 0.76).opacity(0.85), radius: 4)
                .shadow(color: Color(red: 1, green: 0.67, blue: 0.43).opacity(0.6),  radius: 12)
                .shadow(color: Color(red: 1, green: 0.51, blue: 0.27).opacity(0.35), radius: 24)
        }
        .onAppear {
            withAnimation(.linear(duration: cycle)) { drainProgress = 0 }
        }
    }
}

// MARK: - Recording

struct RecordingCard: View {
    let onStop: () -> Void
    @SwiftUI.State private var elapsed: TimeInterval = 0
    @SwiftUI.State private var paused = false
    @SwiftUI.State private var t0 = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // attached tab
            HStack { Text("Sidekey meeting notes").font(.system(size: 13)) }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12, bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0, topTrailingRadius: 12
                    )
                    .fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.08)],
                                         startPoint: .top, endPoint: .bottom))
                )
                .padding(.leading, 18)
                .offset(y: 10)

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    TimerLabel(elapsed: elapsed)
                    Waveform(barCount: 220)
                        .frame(height: 90)
                }
                VStack(spacing: 8) {
                    IconButton(systemName: paused ? "play.fill" : "pause.fill") {
                        paused.toggle()
                    }
                    StopButton(action: onStop)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
        }
        .frame(width: 640)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if !paused { elapsed = Date().timeIntervalSince(t0) }
                else       { t0 = Date().addingTimeInterval(-elapsed) }
            }
        }
    }
}

struct TimerLabel: View {
    let elapsed: TimeInterval
    var body: some View {
        let total = Int(elapsed)
        Text(String(format: "%02d:%02d", total/60, total%60))
            .font(.system(size: 40, weight: .light, design: .monospaced))
            .kerning(-0.8)
            .foregroundStyle(.white)
            .monospacedDigit()
    }
}

// MARK: - Waveform (PROTOTYPE — TimelineView with sine math.
// PRODUCTION must drive bars from real audio levels via MeetingRecorder.audioLevelStream.)

struct Waveform: View {
    let barCount: Int
    @SwiftUI.State private var phases: [Double] = []

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(0..<barCount, id: \.self) { i in
                        let x = Double(i) / Double(barCount - 1)
                        let wave1 = sin(x * .pi * 2.3 - t * 0.8)
                        let wave2 = sin(x * .pi * 5.1 + t * 0.55)
                        let shape = wave1 * 0.55 + wave2 * 0.18 + 0.62
                        let edge  = sin(.pi * x)
                        let phase = phases.indices.contains(i) ? phases[i] : 0
                        let jitter = (sin(t * 14 + phase) * 0.5 + 0.5) * 0.35 + 0.65
                        let h = max(3, shape * edge * jitter * 0.85 * geo.size.height)
                        Capsule()
                            .fill(.white.opacity(0.85))
                            .frame(width: 1.5, height: h)
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
            phases = (0..<barCount).map { _ in Double.random(in: 0..<(2*Double.pi)) }
        }
    }
}

// MARK: - Buttons

struct IconButton: View {
    let systemName: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

struct StopButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color(red: 1, green: 0.49, blue: 0.23))
                .frame(width: 11, height: 11)
                .shadow(color: Color(red: 1, green: 0.49, blue: 0.23).opacity(0.55), radius: 4)
                .frame(width: 38, height: 38)
                .background(
                    LinearGradient(colors: [.white, Color(white: 0.92)],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 10)
                )
        }
        .buttonStyle(.plain)
    }
}
