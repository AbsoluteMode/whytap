import AppKit
import XCTest
@testable import Sidekey

final class SidekeyWindowChromeTests: XCTestCase {
    func test_centeredOriginPlacesWindowInMiddleOfVisibleScreen() {
        let visibleFrame = NSRect(x: 120, y: 80, width: 1440, height: 900)
        let windowSize = NSSize(width: 380, height: 196)

        let origin = SidekeyWindowChrome.centeredOrigin(
            windowSize: windowSize,
            in: visibleFrame
        )

        XCTAssertEqual(origin.x, 650)
        XCTAssertEqual(origin.y, 432)
    }

    func test_visibleFrameContainingPointUsesMatchingScreenCandidate() {
        let left = SidekeyWindowChrome.ScreenCandidate(
            frame: NSRect(x: -1440, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: -1440, y: 40, width: 1440, height: 820)
        )
        let main = SidekeyWindowChrome.ScreenCandidate(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 44, width: 1512, height: 900)
        )

        let visibleFrame = SidekeyWindowChrome.visibleFrame(
            containing: NSPoint(x: -20, y: 500),
            candidates: [main, left]
        )

        XCTAssertEqual(visibleFrame, left.visibleFrame)
    }

    func test_preferredVisibleFrameDoesNotDependOnCursorLocation() throws {
        let sourceURL = try projectRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("WindowChrome")
            .appendingPathComponent("SidekeyWindowChrome.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        guard let functionRange = source.range(of: "static func preferredVisibleFrame") else {
            XCTFail("SidekeyWindowChrome should expose preferredVisibleFrame(for:).")
            return
        }
        let functionSource = source[functionRange.lowerBound...]

        XCTAssertFalse(
            functionSource.contains("NSEvent.mouseLocation"),
            "Centered app windows must not choose their display from the current cursor location."
        )
        XCTAssertTrue(
            functionSource.contains("primaryVisibleFrame"),
            "Preferred centering should anchor to the primary display's visible frame."
        )
    }

    func test_primaryVisibleFrameUsesDisplayAtCoordinateOrigin() {
        let left = SidekeyWindowChrome.ScreenCandidate(
            frame: NSRect(x: -1440, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: -1440, y: 40, width: 1440, height: 820)
        )
        let primary = SidekeyWindowChrome.ScreenCandidate(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 44, width: 1512, height: 900)
        )
        let right = SidekeyWindowChrome.ScreenCandidate(
            frame: NSRect(x: 1512, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 1512, y: 40, width: 1440, height: 820)
        )

        let visibleFrame = SidekeyWindowChrome.primaryVisibleFrame(
            candidates: [left, right, primary]
        )

        XCTAssertEqual(visibleFrame, primary.visibleFrame)
    }

    func test_sidekeyWindowsUseSharedMainScreenCenteringInsteadOfNSWindowCenter() throws {
        let root = try projectRoot()
        let relativePaths = [
            "Sources/Sidekey/Settings/SettingsWindowController.swift",
            "Sources/Sidekey/WindowChrome/SidekeyQuitConfirmationController.swift",
            "Sources/Sidekey/Meetings/MeetingsWindowController.swift",
            "Sources/Sidekey/HelpWindowController.swift",
            "Sources/Sidekey/History/HistoryWindowController.swift",
            "Sources/Sidekey/OnboardingWindowController.swift"
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )

            let usesSharedCentering = source.contains("SidekeyWindowChrome.centerOnMainScreen(window)")
                || source.contains("SidekeyWindowChrome.center(window, inVisibleFrame: openingVisibleFrame)")
            XCTAssertTrue(usesSharedCentering, "\(relativePath) should use shared centering.")
            XCTAssertFalse(
                source.contains("window.center()"),
                "\(relativePath) should not use NSWindow.center()."
            )
            XCTAssertFalse(
                source.contains("private func centerOnMainScreen()"),
                "\(relativePath) should not carry a local centering helper."
            )
        }
    }

    func test_sidekeyWindowsRecenterAfterOrderingForFirstSwiftUILayoutPass() throws {
        let root = try projectRoot()
        let expectations = [
            ("Sources/Sidekey/Settings/SettingsWindowController.swift", "window.makeKeyAndOrderFront(nil)"),
            ("Sources/Sidekey/WindowChrome/SidekeyQuitConfirmationController.swift", "window.makeKeyAndOrderFront(nil)"),
            ("Sources/Sidekey/Meetings/MeetingsWindowController.swift", "window.makeKeyAndOrderFront(nil)"),
            ("Sources/Sidekey/HelpWindowController.swift", "window.orderFrontRegardless()"),
            ("Sources/Sidekey/History/HistoryWindowController.swift", "window.makeKeyAndOrderFront(nil)"),
            ("Sources/Sidekey/OnboardingWindowController.swift", "window.makeKeyAndOrderFront(nil)")
        ]

        for (relativePath, orderCall) in expectations {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            guard let orderRange = source.range(of: orderCall) else {
                XCTFail("\(relativePath) should order the window with \(orderCall).")
                continue
            }
            let remainingSource = source[orderRange.upperBound...]

            let recentersAfterOrdering = remainingSource.contains("SidekeyWindowChrome.centerOnMainScreen(window)")
                || remainingSource.contains("SidekeyWindowChrome.center(window, inVisibleFrame: openingVisibleFrame)")
            XCTAssertTrue(
                recentersAfterOrdering,
                "\(relativePath) should re-center after ordering so first SwiftUI layout cannot shift it."
            )
        }
    }

    func test_hoverOpenedWindowsUseFullscreenOverlayPolicy() throws {
        let root = try projectRoot()
        let relativePaths = [
            "Sources/Sidekey/Settings/SettingsWindowController.swift",
            "Sources/Sidekey/HelpWindowController.swift",
            "Sources/Sidekey/WindowChrome/SidekeyQuitConfirmationController.swift"
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )

            XCTAssertTrue(
                source.contains("SidekeyWindowChrome.configureHoverOverlayPolicy(window)"),
                "\(relativePath) should use the shared hover overlay fullscreen policy."
            )
            XCTAssertFalse(
                source.contains("window.level = .floating"),
                "\(relativePath) should not stay at floating level; it can disappear behind another app's fullscreen Space."
            )
            XCTAssertFalse(
                source.contains("FullScreenBringForward.acquire()"),
                "\(relativePath) should not use the onboarding-style desktop bring-forward path."
            )
        }
    }

    @MainActor
    func test_configureHoverOverlayPolicyMatchesProductionFullscreenLayer() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        SidekeyWindowChrome.configureHoverOverlayPolicy(window)

        XCTAssertEqual(window.level.rawValue, NSWindow.Level.statusBar.rawValue)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.collectionBehavior.contains(.stationary))
        XCTAssertFalse(window.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone))
    }

    func test_hoverOpenedWindowsOrderFrontRegardlessBeforeKeyOrdering() throws {
        let root = try projectRoot()
        let relativePaths = [
            "Sources/Sidekey/Settings/SettingsWindowController.swift",
            "Sources/Sidekey/HelpWindowController.swift",
            "Sources/Sidekey/WindowChrome/SidekeyQuitConfirmationController.swift"
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )

            guard let activateRange = source.range(of: "NSApp.activate(ignoringOtherApps: true)"),
                  let orderRegardlessRange = source.range(of: "window.orderFrontRegardless()"),
                  let keyOrderRange = source.range(of: "window.makeKeyAndOrderFront(nil)") else {
                XCTFail("\(relativePath) should activate, order front regardless, and become key.")
                continue
            }

            XCTAssertLessThan(
                activateRange.lowerBound,
                orderRegardlessRange.lowerBound,
                "\(relativePath) should activate before force-ordering the window."
            )
            XCTAssertLessThan(
                orderRegardlessRange.lowerBound,
                keyOrderRange.lowerBound,
                "\(relativePath) should force the window above other apps before making it key."
            )
        }
    }

    func test_configureKeepsSystemTitlebarButtonsVisible() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("WindowChrome")
            .appendingPathComponent("SidekeyWindowChrome.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("window.standardWindowButton(.closeButton)?.isHidden = false"))
        XCTAssertTrue(source.contains("window.standardWindowButton(.miniaturizeButton)?.isHidden = false"))
        XCTAssertTrue(source.contains("window.standardWindowButton(.zoomButton)?.isHidden = false"))
        XCTAssertFalse(source.contains("SidekeyWindowButtonLayout"))
    }

    func test_configureRemovesTitlebarVisualChrome() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("WindowChrome")
            .appendingPathComponent("SidekeyWindowChrome.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("window.styleMask.insert(.fullSizeContentView)"))
        XCTAssertTrue(source.contains("window.titlebarAppearsTransparent = true"))
        XCTAssertTrue(source.contains("window.titleVisibility = .hidden"))
        XCTAssertTrue(source.contains("window.titlebarSeparatorStyle = .none"))
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
        throw NSError(domain: "SidekeyWindowChromeTests", code: 1)
    }
}
