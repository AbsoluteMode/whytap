import Foundation

enum AppCompatibility {
    private static let replaceSelectionAllowlist = [
        "slack",
        "tinyspeck",
        "notion",
        "linear",
        "cursor",
        "vscode",
        "visualstudio",
        "microsoft.vscode",
        "todesktop.230313mzl4w4u92"
    ]

    private static let pasteOnlyList = [
        "mail",
        "messages",
        "terminal",
        "com.apple.mail",
        "com.apple.messages",
        "com.apple.mobilesms",
        "com.apple.ichat",
        "com.apple.terminal"
    ]

    static func supportsReplaceSelection(bundleID: String?) -> Bool {
        guard let bundleID else {
            return false
        }

        let normalized = bundleID.lowercased()
        if pasteOnlyList.contains(where: normalized.contains) {
            return false
        }

        return replaceSelectionAllowlist.contains(where: normalized.contains)
    }
}
