import Foundation

/// What the learning step knows about the field a take was pasted into. Read
/// through Accessibility at paste time and again before the one read.
struct DropEditFieldFacts: Equatable {
    var bundleID: String?
    var isOwnProcess: Bool
    var role: String?
    var subrole: String?
    var secureEventInput: Bool
    /// The field exposes its text as a string `AXValue`.
    var hasStringValue: Bool
    /// Any Accessibility call needed for these facts failed.
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

    static func allowsRead(_ facts: DropEditFieldFacts) -> Bool {
        guard !facts.accessibilityError, !facts.secureEventInput, !facts.isOwnProcess else { return false }
        guard let bundleID = facts.bundleID, !deniedBundleIDs.contains(bundleID) else { return false }
        if let subrole = facts.subrole, secureSubroles.contains(subrole) { return false }
        guard let role = facts.role, textRoles.contains(role) || role == "AXWebArea" else { return false }
        // Electron and some web composers do not expose the text: skip.
        return facts.hasStringValue
    }
}
