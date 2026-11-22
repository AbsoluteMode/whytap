import Foundation
import Sidekey

// The onboarding alone, outside Whytap: `scripts/onboarding-preview.sh`.
// Fonts and logos come from this checkout's Resources, as the app bundle would carry them.
let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources", isDirectory: true)

MainActor.assumeIsolated {
    OnboardingPreview.run(resources: resources)
}
