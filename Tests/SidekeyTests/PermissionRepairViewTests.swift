import SwiftUI
import XCTest
@testable import Sidekey

/// Guards the regression where the standalone permission-repair window rendered
/// invisible on launch. `SidekeyWindowChrome` makes the hosting window
/// transparent (clear background, `isOpaque = false`, no shadow), so the repair
/// view MUST paint its own opaque fill — otherwise `makeKeyAndOrderFront` shows
/// a see-through window the user reads as "no window at all" (the app even keeps
/// its Dock icon from the `.regular` promotion, which made the bug especially
/// confusing). Mirrors the source-contains style of `OnboardingWindowControllerTests`,
/// the project's convention for window-visibility invariants that can't be
/// asserted via rendering.
@MainActor
final class PermissionRepairViewTests: XCTestCase {
    func test_repairViewPaintsOpaqueBackground() throws {
        let source = try repairViewSource()

        XCTAssertTrue(
            source.contains(".background(OnboardingTheme.bg"),
            "PermissionRepairView must paint an opaque OnboardingTheme.bg fill; without it the transparent SidekeyWindowChrome window renders invisible."
        )
    }

    func test_repairWindowReliesOnTransparentChrome() throws {
        // Premise check: the opaque-background requirement above only matters
        // because the window controller adopts the shared transparent chrome.
        // If that ever stops being true, revisit the background guard.
        let source = try repairWindowControllerSource()

        XCTAssertTrue(
            source.contains("SidekeyWindowChrome.configure(window)"),
            "Repair window relies on the shared transparent chrome — that is exactly why the view must paint its own opaque background."
        )
    }

    // MARK: - Source loaders

    private func repairViewSource() throws -> String {
        try source(at: ["Sources", "Sidekey", "Permissions", "PermissionRepairView.swift"])
    }

    private func repairWindowControllerSource() throws -> String {
        try source(at: ["Sources", "Sidekey", "Permissions", "PermissionRepairWindowController.swift"])
    }

    private func source(at components: [String]) throws -> String {
        var url = try projectRoot()
        for component in components {
            url.appendPathComponent(component)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "PermissionRepairViewTests", code: 1)
    }
}
