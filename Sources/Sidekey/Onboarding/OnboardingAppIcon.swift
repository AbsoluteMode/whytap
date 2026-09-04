import AppKit
import SwiftUI

/// Loads a real, full-colour application icon (e.g. the Whytap / Voice Memos /
/// Slack / Telegram `.app` icon, pre-extracted into
/// `UsefulLinkIcons/<name>.png`). The preview target ships these in
/// `Bundle.module`; the Sidekey app ships them in `Bundle.main` (same path the
/// notification pill already uses for brand glyphs). Returns nil when absent so
/// callers can fall back to a drawn / SF-symbol placeholder.
func onboardingAppIcon(_ name: String) -> NSImage? {
    #if ONBOARDING_PREVIEW
    let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "UsefulLinkIcons")
    #else
    let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "UsefulLinkIcons")
    #endif
    guard let url else { return nil }
    return NSImage(contentsOf: url)
}
