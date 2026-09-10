import AppKit

/// Stop temporary disk-image copies before they request permissions or start
/// the updater. Installing is a Finder action; no existing app is overwritten.
// WHY: .project-docs/decisions/2026-09-10-public-installation.md
enum InstallationGuard {
    static func requiresInstallation(bundleURL: URL, volumeIsReadOnly: Bool) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        return volumeIsReadOnly || bundleURL.pathComponents.contains("AppTranslocation")
    }

    @MainActor
    static func canLaunch(bundle: Bundle = .main) -> Bool {
        let url = bundle.bundleURL
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        guard requiresInstallation(bundleURL: url, volumeIsReadOnly: readOnly) else { return true }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install Whytap before opening it"
        alert.informativeText = "Drag Whytap to the Applications folder in the disk image, then open Whytap from Applications. This gives permissions and updates a permanent home. This temporary copy will now quit."
        alert.addButton(withTitle: "Open Applications")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
        return false
    }

    /// Release verification can launch both slices without creating app state,
    /// reading keys, contacting providers or requesting system permissions.
    static func installationCheck(bundle: Bundle = .main) -> Bool {
        guard let resources = bundle.resourceURL else { return false }
        let required = ["mlx.metallib", "Fonts", "blocknote/index.html", "AppIcon.icns"]
        let files = FileManager.default
        guard required.allSatisfy({ files.fileExists(atPath: resources.appendingPathComponent($0).path) }),
              files.fileExists(atPath: bundle.bundleURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework").path)
        else { return false }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") != nil
            && bundle.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }
}
