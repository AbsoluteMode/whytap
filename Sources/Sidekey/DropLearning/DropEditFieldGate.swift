import Foundation

/// What the learning step knows about the field a take was pasted into: its
/// identity and security metadata, read through Accessibility before the paste
/// and again before every read. Never derived from the field's text.
struct DropEditFieldFacts: Equatable {
    var bundleID: String?
    var isOwnProcess: Bool
    var role: String?
    var subrole: String?
    var secureEventInput: Bool
    /// An Accessibility call for these facts failed (other than a missing
    /// attribute).
    var accessibilityError: Bool
}

/// Fail-closed gate for reading a field after Drop. `PasteTargetValidator`
/// is not a password gate: it accepts any text field before looking at its
/// subrole and says yes on AX errors. Anything unknown here means no read.
/// WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
enum DropEditFieldGate {
    /// Terminals (typed secrets, shell history) and password managers.
    static let deniedBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio", "dev.zed.Zed-Terminal",
        "com.apple.keychainaccess", "com.apple.Passwords",
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass", "in.sinew.Enpass-Desktop", "com.proton.pass", "me.proton.pass.electron",
        "com.nordpass.macos.NordPass", "com.keepersecurity.passwordmanager",
    ]

    static let secureSubroles: Set<String> = ["AXSecureTextField"]
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func allowsRead(_ facts: DropEditFieldFacts) -> Bool { refusal(facts) == nil }

    /// Why the gate says no, as a fixed name (the dev journal and the
    /// reason counters); nil when it allows the read.
    static func refusal(_ facts: DropEditFieldFacts) -> String? {
        if facts.accessibilityError { return "axError" }
        if facts.secureEventInput { return "secureInput" }
        if facts.isOwnProcess { return "ownProcess" }
        guard let bundleID = facts.bundleID else { return "unknownApp" }
        if deniedBundleIDs.contains(bundleID) { return "deniedApp" }
        if let subrole = facts.subrole, secureSubroles.contains(subrole) { return "secureField" }
        // A field that does not expose its text as a string is skipped at
        // the read; Electron and web views first get their tree turned on
        // (`mayExpose`).
        guard let role = facts.role, textRoles.contains(role) else { return "notTextRole" }
        return nil
    }

    /// The app may be asked to expose its fields: everything the read gate
    /// checks except the role, which is what the app does not report yet.
    /// WHY: .project-docs/decisions/2026-11-22-drop-edit-observation.md
    static func mayExpose(_ facts: DropEditFieldFacts) -> Bool {
        guard !facts.accessibilityError, !facts.secureEventInput, !facts.isOwnProcess else { return false }
        guard let bundleID = facts.bundleID, !deniedBundleIDs.contains(bundleID) else { return false }
        if let subrole = facts.subrole, secureSubroles.contains(subrole) { return false }
        return true
    }
}
