import AVFoundation
import Foundation
import SwiftUI

/// Drives a real `VoiceOrbView` through a scripted timeline so the
/// welcome screen plays a live "tap → speak → think → insert" demo
/// without needing hotkey wiring, mic permission, or real audio
/// input. The orb itself is the production component — only the
/// `mode` flag and the `levels` feed are synthetic.
///
/// `audioURL` (optional): when supplied, the recording phase plays
/// the file via `AVAudioPlayer` and feeds the orb live average-power
/// metering converted to a `[0..1]` level. When nil, the recording
/// phase falls back to a synthetic sine envelope. The Sidekey app
/// passes nil; `OnboardingPreview` passes the bundled ElevenLabs
/// sample so the orb visibly reacts to a real voice.
@MainActor
final class OnboardingOrbController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case pressFlash
        case recording
        case pressFlashAgain
        case thinking
        case done
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var levels: [Float] = [0]
    @Published private(set) var typed: String = ""
    /// Mute toggle wired to the preview's speaker button. The orb still
    /// reacts to the metered levels — only the audio output is
    /// silenced — so the demo stays visually identical when muted.
    @Published var isMuted: Bool = false {
        didSet { audioPlayer?.volume = isMuted ? 0 : 1 }
    }

    let transcript: String
    let audioURL: URL?

    private var task: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?

    /// Lower / upper dB cutoffs for converting `AVAudioPlayer.averagePower`
    /// into a `[0..1]` level. -50 dB ≈ silence, 0 dB ≈ full scale; the
    /// span maps linearly into the orb's working range so the visible
    /// motion tracks the voice.
    private static let meterFloorDB: Float = -50
    private static let meterCeilingDB: Float = 0

    init(
        transcript: String = "Hey agent, let’s start with the auth bug. Check why users get logged out after refresh, find the root cause, and suggest the smallest safe fix.",
        audioURL: URL? = nil
    ) {
        self.transcript = transcript
        self.audioURL = audioURL
    }

    deinit {
        task?.cancel()
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.runCycle()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        audioPlayer?.stop()
        audioPlayer = nil
        phase = .idle
        levels = [0]
        typed = ""
    }

    func toggleMute() {
        isMuted.toggle()
    }

    // MARK: - Cycle

    private func runCycle() async {
        await runIdle(duration: 1.2)
        guard !Task.isCancelled else { return }

        phase = .pressFlash
        await sleep(0.36)
        guard !Task.isCancelled else { return }

        phase = .recording
        await runRecording()
        guard !Task.isCancelled else { return }

        // Flash the second keycap while the orb is already in its
        // thinking mode — `OnboardingWelcomeScreen.mode(for:)` maps
        // `.pressFlashAgain` to `.dropProcessing` so VoiceOrbView
        // transitions straight from voice → processing without
        // collapsing back to the idle ring between frames.
        phase = .pressFlashAgain
        levels = [0]
        await sleep(0.36)
        guard !Task.isCancelled else { return }

        phase = .thinking
        await sleep(1.6)
        guard !Task.isCancelled else { return }

        // Drop-style insert: full transcript appears at once (no
        // typewriter streaming — matches the production paste pipeline
        // which lands the entire decoded text in one CGEvent burst).
        typed = transcript
        phase = .done
        await sleep(3.0)
    }

    private func runIdle(duration: TimeInterval) async {
        phase = .idle
        levels = [0]
        typed = ""
        await sleep(duration)
    }

    /// Plays the bundled audio (if available) and pumps live metering
    /// into `levels`, so the orb reacts to the real voice. When no
    /// audio URL was supplied falls back to a synthetic envelope that
    /// keeps the orb visibly alive for the same duration window.
    private func runRecording() async {
        if let url = audioURL {
            await playAudioWithMetering(url: url)
        } else {
            await runSyntheticEnvelope(duration: 2.4)
        }
    }

    private func playAudioWithMetering(url: URL) async {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.isMeteringEnabled = true
            player.volume = isMuted ? 0 : 1
            player.prepareToPlay()
            audioPlayer = player
            player.play()

            while !Task.isCancelled, player.isPlaying {
                player.updateMeters()
                let power = player.averagePower(forChannel: 0)
                levels = [Self.linearLevel(fromDB: power)]
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            player.stop()
            audioPlayer = nil
        } catch {
            NSLog("OnboardingOrbController: audio playback failed — %@",
                  String(describing: error))
            await runSyntheticEnvelope(duration: 2.4)
        }
    }

    /// Slow breath (sin(t * 1.8)) modulated by faster bursts plus
    /// small jitter, clamped into [0.18, 0.95]. Used when no audio
    /// sample is bundled so the orb still cycles visibly.
    private func runSyntheticEnvelope(duration: TimeInterval) async {
        let start = Date()
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= duration { break }
            let breath = (sin(elapsed * 1.8) + 1) * 0.5
            let burst = sin(elapsed * 7.5 + 1.2) * 0.18
            let jitter = Double.random(in: -0.04...0.04)
            let raw = breath * 0.7 + burst + jitter + 0.18
            let level = max(0.18, min(0.95, raw))
            levels = [Float(level)]
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// dB → linear, clamped to the orb's useful response range.
    /// `AVAudioPlayer.averagePower` returns -160…0 dB; we floor at
    /// -50 dB (everything below reads as silence) and map [-50, 0]
    /// linearly into [0, 1].
    private static func linearLevel(fromDB db: Float) -> Float {
        let clamped = max(meterFloorDB, min(meterCeilingDB, db))
        let span = meterCeilingDB - meterFloorDB
        return (clamped - meterFloorDB) / span
    }
}
