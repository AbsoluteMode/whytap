import Foundation

/// Apple-Silicon capability gate for the on-device model stack (ROO-257).
///
/// MLX (the local LLM runtime) and the FluidAudio Core ML diarizer/Parakeet
/// models run on the Apple Neural Engine / Metal and are **Apple-Silicon-only**.
/// The app ships a UNIVERSAL binary, so a compile-time `#if arch(arm64)` is
/// wrong: an Intel slice (or an arm64 build running under Rosetta translation)
/// would mis-report support. We probe the real CPU at runtime via
/// `sysctlbyname("hw.optional.arm64")`, which reflects the executing hardware
/// regardless of the binary slice. Local STT (ROO-256) shipped without this
/// gate; ROO-257 adds it as the single source of truth for both LLM and
/// diarization.
///
/// WHY (runtime sysctl, not `#if arch`): docs/decisions/2026-06-26-local-llm.md
enum LocalModelSupport {
    /// `true` when the executing CPU is Apple Silicon. Evaluated once at first
    /// access; the hardware never changes during a process lifetime.
    ///
    /// Intel simulation in tests goes through the closure-injection seam at the
    /// call sites (e.g. `SettingsModelsViewModel.init(isAppleSilicon:)`,
    /// `MeetingsCoordinator`), so no extra pass-through is needed here.
    static let isAppleSilicon: Bool = detectAppleSilicon()

    /// Read `hw.optional.arm64` from sysctl. Returns `1` on Apple Silicon and
    /// `0` (or an absent key) on Intel. Any failure is treated as "not Apple
    /// Silicon" so the gate fails closed — the local stack is hidden rather than
    /// offered on hardware that cannot run it.
    static func detectAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }
}

/// Canonical user-facing strings for the on-device model paths. Consolidated so
/// Settings, Drop cleanup, and Meeting notes surface the **same** copy for the
/// shared failure modes (unsupported hardware, offline-can't-download,
/// not-yet-downloaded) instead of three slightly different sentences.
enum LocalModelMessaging {
    /// Shown when the user is on Intel and the local stack is unavailable.
    static let requiresAppleSilicon = "Local models require Apple Silicon."

    /// Shown when a download is attempted while offline — the weights cannot be
    /// fetched without a connection. Note: once downloaded, inference itself
    /// works fully offline (that is the point of the local path).
    static let offlineCannotDownload =
        "You're offline — connect to the internet to download the model."

    /// Shown when a local level is selected/used but the weights are not present
    /// on disk yet.
    static let modelNotDownloaded = "Download the local model first."

    /// Shown on a meeting row when a recording finished but neither the
    /// on-device models nor a BYOK stack is configured to process it. The
    /// staged audio is kept and retried on the next launch.
    static let meetingProcessorNotConfigured =
        "Set up local models or your own provider keys in Settings > Models to process this meeting."
}

extension NSError {
    /// Walk the underlying-error chain looking for a `URLError`. Model-download
    /// failures from the HuggingFace Hub layer often wrap the real connectivity
    /// error in `NSUnderlyingErrorKey`, so the top-level cast alone misses the
    /// offline case the unified messaging needs to detect.
    var underlyingURLError: URLError? {
        var current: NSError? = self
        var depth = 0
        while let error = current, depth < 5 {
            if let urlError = error as? URLError { return urlError }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}
