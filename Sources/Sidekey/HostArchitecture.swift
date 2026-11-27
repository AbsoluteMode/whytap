import Foundation

/// Runtime Apple Silicon probe. Formerly `LocalModelSupport`, named after the
/// on-device model stack it gated until that stack was removed; it picks the
/// default for a processing route the user never chose (`SelfKeyPreferences`).
///
/// The app ships a UNIVERSAL binary, so a compile-time `#if arch(arm64)` is
/// wrong: an Intel slice (or an arm64 build running under Rosetta translation)
/// would mis-report support. We probe the real CPU at runtime via
/// `sysctlbyname("hw.optional.arm64")`, which reflects the executing hardware
/// regardless of the binary slice.
///
/// WHY (runtime sysctl, not `#if arch`): docs/decisions/2026-06-26-local-llm.md
enum HostArchitecture {
    /// `true` when the executing CPU is Apple Silicon. Evaluated once at first
    /// access; the hardware never changes during a process lifetime.
    ///
    /// Tests simulate either architecture through the injection seams at the
    /// call sites (e.g. `SelfKeyPreferences.init(isAppleSilicon:)`), so no
    /// extra pass-through is needed here.
    static let isAppleSilicon: Bool = detectAppleSilicon()

    /// Read `hw.optional.arm64` from sysctl. Returns `1` on Apple Silicon and
    /// `0` (or an absent key) on Intel. Any failure is treated as "not Apple
    /// Silicon".
    static func detectAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }
}
