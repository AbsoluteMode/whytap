import Foundation

enum AgentFeatureGate {
    private static let voiceProviderReady = true

    static var isEnabled: Bool {
        isEnabled(for: BuildConfig.flavor)
    }

    static var isVoiceEnabled: Bool {
        isVoiceEnabled(for: BuildConfig.flavor)
    }

    static var isTextEnabled: Bool {
        isTextEnabled(for: BuildConfig.flavor)
    }

    static func isEnabled(for flavor: BuildFlavor) -> Bool {
        // Agent UI is enabled on every flavor; the flavor gate was only a UX
        // rollout switch.
        _ = flavor
        return true
    }

    static func isVoiceEnabled(
        for flavor: BuildFlavor,
        providerReady: Bool = voiceProviderReady
    ) -> Bool {
        isEnabled(for: flavor) && providerReady
    }

    static func isTextEnabled(for flavor: BuildFlavor) -> Bool {
        isEnabled(for: flavor)
    }

    /// When true, R-Cmd hold drives realtime streaming transcription
    /// (streaming session → transcript → local agent CLI) instead of
    /// the batch record-then-send path. Mutually exclusive with direct-audio
    /// for voice: streaming sends text, not raw WAV.
    static let streamingVoiceEnabled = true

    /// When true, a Drop turn whose live stream degrades mid-recording (a
    /// network blip tears down the WS / the upstream stalls) is recovered by
    /// batch-transcribing the locally-retained PCM instead of being dropped.
    /// Gated inside the streaming sessions (every degrade decision) so the
    /// off-path is bit-for-bit the old behavior; the AppDelegate batch-recover
    /// router only ever sees `.degraded` when this is on.
    ///
    /// Rollout: **ON on every flavor** (promoted to prod 2026-06-20, right after
    /// the beta build shipped). The off-path is bit-for-bit the old behavior, and
    /// the worst case of a false-positive degrade is a (correct) batch-recovered
    /// turn — text is never lost, only re-delivered slightly slower — so the
    /// bounded downside justified skipping the beta soak. The stall
    /// (`defaultStallSeconds`) / stop-watchdog thresholds may still be tuned
    /// against `DropTurnTrace`; gate a flavor back off here if a regression
    /// appears. WHY: docs/decisions/2026-06-20-resilient-drop-prod-activation.md
    static var resilientDropDeliveryEnabled: Bool {
        resilientDropDeliveryEnabled(for: BuildConfig.flavor)
    }

    static func resilientDropDeliveryEnabled(for flavor: BuildFlavor) -> Bool {
        _ = flavor
        return true
    }
}
