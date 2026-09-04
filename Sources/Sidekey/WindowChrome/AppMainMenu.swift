import AppKit

/// Accessory (LSUIElement, `.accessory` activation policy) apps ship without a
/// menu bar. That also strips the standard text-editing key equivalents
/// (⌘X/⌘C/⌘V/⌘A, ⌘Z) of a command target in the responder chain — so pasting
/// into ANY text field (e.g. the Settings → Models API-key field) just emits a
/// system beep. Installing a minimal main menu with an Edit submenu restores
/// those shortcuts; the items are nil-targeted so they dispatch to the focused
/// field editor via the responder chain. The menu bar stays hidden under
/// `.accessory`.
enum AppMainMenu {
    static func installIfNeeded() {
        let menu = NSMenu()

        // First submenu is treated as the application menu.
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // Edit menu — the part that actually restores paste. nil target →
        // routed to the first responder (the focused text field's editor).
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        NSApp.mainMenu = menu
    }

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Whytap"
    }
}
