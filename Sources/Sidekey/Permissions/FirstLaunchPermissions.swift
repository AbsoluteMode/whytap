import Foundation

/// This marker belongs to the Mac, not to the portable settings backup.
// WHY: .project-docs/decisions/2026-10-26-first-launch-permissions.md
enum FirstLaunchPermissions {
    static let presentedKey = "sidekey.permissions.firstLaunchPresented.v1"

    static func consumePresentation(in defaults: UserDefaults,
                                    requiredPermissionsGranted: Bool,
                                    screenRecordingGranted: Bool) -> Bool {
        guard !defaults.bool(forKey: presentedKey) else { return false }
        defaults.set(true, forKey: presentedKey)
        return !requiredPermissionsGranted || !screenRecordingGranted
    }
}
