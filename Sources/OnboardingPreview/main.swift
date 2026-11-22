import Foundation
import Sidekey

// The onboarding alone, outside Whytap: `scripts/onboarding-preview.sh`.
// Fonts come from this checkout's Resources, as the app bundle would carry them.
let fonts = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Fonts", isDirectory: true)

MainActor.assumeIsolated {
    OnboardingPreview.run(fontsDirectory: fonts)
}
