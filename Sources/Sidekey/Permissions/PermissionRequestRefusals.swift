import CoreGraphics
import Foundation

/// Permission requests this macOS refused without asking the person.
///
/// macOS 27.3 beta 2 answers a new app's keyboard control (Accessibility)
/// and Screen Recording requests with no dialog and no row in System
/// Settings; the only way left is adding the app by hand with "+", which
/// Whytap never sends a person to. A request counts as refused by what
/// happened, not by a version number: no system permission dialog appeared
/// and access is still off a few seconds after the request. The check runs
/// only where the old Accessibility pane is gone (27.3 and later), so an
/// older macOS that shows no second dialog is never taken for this one.
/// A refusal is remembered for this macOS build only: after an update the
/// first Allow asks macOS again.
// WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
@MainActor
final class PermissionRequestRefusals: ObservableObject {
    enum Kind: String, CaseIterable {
        case keyboard
        case screen
    }

    static let shared = PermissionRequestRefusals()
    static let defaultsKey = "sidekey.permissions.refusedRequests.v1"
    /// How long macOS gets to show its own dialog after a request.
    static let promptWait: TimeInterval = 2.5

    /// Requests refused on this macOS build.
    @Published private(set) var refused: Set<Kind>
    /// Requests whose answer is being watched right now.
    @Published private(set) var checking: Set<Kind> = []

    private let applies: () -> Bool
    private let promptAppeared: (TimeInterval) async -> Bool
    private let defaults: UserDefaults?
    private let build: String

    /// `defaults` nil keeps refusals in memory only (tests, the preview).
    init(applies: @escaping () -> Bool = { PermissionsHelper.usesProtectionOverridePane },
         promptAppeared: @escaping (TimeInterval) async -> Bool = { await SystemPermissionPrompt.appears(within: $0) },
         defaults: UserDefaults? = .standard,
         build: String = SystemPermissionPrompt.osBuild) {
        self.applies = applies
        self.promptAppeared = promptAppeared
        self.defaults = defaults
        self.build = build
        let stored = defaults?.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        refused = applies() ? Set(Kind.allCases.filter { stored[$0.rawValue] == build }) : []
    }

    /// After a request: waits for macOS's own dialog and records a refusal
    /// when none came and access is still off. Returns whether it refused.
    @discardableResult
    func check(_ kind: Kind, granted: @escaping () -> Bool) async -> Bool {
        guard applies(), !checking.contains(kind), !refused.contains(kind) else { return refused.contains(kind) }
        checking.insert(kind)
        let asked = await promptAppeared(Self.promptWait)
        checking.remove(kind)
        guard !asked, !granted() else { return false }
        refused.insert(kind)
        save()
        return true
    }

    /// Access arrived after all (a later build, or added by hand): forget.
    func clear(_ kind: Kind) {
        guard refused.contains(kind) else { return }
        refused.remove(kind)
        save()
    }

    private func save() {
        guard let defaults else { return }
        var stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        for kind in Kind.allCases {
            if refused.contains(kind) { stored[kind.rawValue] = build } else { stored[kind.rawValue] = nil }
        }
        if stored.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) } else { defaults.set(stored, forKey: Self.defaultsKey) }
    }
}

/// macOS's own permission dialogs, seen from outside: a window of one of the
/// system agents that show them, opened after the request.
enum SystemPermissionPrompt {
    /// Owners of the windows macOS shows for a permission request (the
    /// Accessibility and Screen Recording alerts, the privacy alert, an
    /// authentication sheet) or of System Settings opened by that alert.
    static let owners: Set<String> = [
        "universalAccessAuthWarn", "UserNotificationCenter", "SecurityAgent",
        "System Settings", "System Preferences",
    ]

    /// This macOS build ("26C5047e"): a refusal is remembered per build.
    static var osBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        return String(cString: value)
    }

    /// Whether a system permission window appeared within `seconds`. Reads
    /// only window owners and numbers, which need no Screen Recording.
    static func appears(within seconds: TimeInterval) async -> Bool {
        let before = promptWindows()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !promptWindows().subtracting(before).isEmpty { return true }
        }
        return false
    }

    static func promptWindows() -> Set<Int> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(windows.compactMap { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String, owners.contains(owner) else { return nil }
            return window[kCGWindowNumber as String] as? Int
        })
    }
}
