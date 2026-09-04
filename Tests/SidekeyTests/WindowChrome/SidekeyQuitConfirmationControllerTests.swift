import XCTest

final class SidekeyQuitConfirmationControllerTests: XCTestCase {
    func test_quitConfirmationUsesAuroraFrameInsteadOfSystemAlert() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("WindowChrome")
            .appendingPathComponent("SidekeyQuitConfirmationController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("SidekeyAuroraWindow(title: \"Quit Whytap\")"))
        XCTAssertTrue(source.contains("Are you sure you want to quit Whytap?"))
        XCTAssertTrue(source.contains("ConfirmQuitButtonStyle"))
        XCTAssertTrue(source.contains("Cancel"))
        XCTAssertFalse(source.contains("NSAlert"))
    }

    func test_islandQuitRoutesThroughConfirmationBeforeTerminate() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("AppDelegate.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private var quitConfirmationController"))
        XCTAssertTrue(source.contains("showQuitConfirmation()"))
        XCTAssertFalse(source.contains("private func quitApplicationFromIsland() {\n        NSApp.terminate(nil)\n    }"))
    }

    func test_quitConfirmationActivatesAppBeforeFirstCentering() throws {
        let source = try quitConfirmationSource()
        guard let showRange = source.range(of: "func show()") else {
            XCTFail("Quit confirmation should expose show().")
            return
        }
        let showSource = source[showRange.lowerBound...]

        guard let activateRange = showSource.range(of: "NSApp.activate(ignoringOtherApps: true)"),
              let centerRange = showSource.range(of: "SidekeyWindowChrome.center(window, inVisibleFrame: openingVisibleFrame)") else {
            XCTFail("show() should activate and center the quit confirmation window.")
            return
        }

        XCTAssertLessThan(
            activateRange.lowerBound,
            centerRange.lowerBound,
            "The first quit confirmation show must activate Sidekey before first visible centering."
        )
    }

    func test_quitConfirmationRecentersSynchronouslyAfterOrdering() throws {
        let source = try quitConfirmationSource()
        guard let orderRange = source.range(of: "window.makeKeyAndOrderFront(nil)") else {
            XCTFail("Quit confirmation should order the window.")
            return
        }
        let afterOrdering = source[orderRange.upperBound...]

        XCTAssertTrue(
            afterOrdering.contains("SidekeyWindowChrome.center(window, inVisibleFrame: openingVisibleFrame)"),
            "Quit confirmation should still re-center after ordering."
        )
    }

    func test_quitConfirmationDoesNotDeferVisibleRecenter() throws {
        let source = try quitConfirmationSource()

        XCTAssertFalse(
            source.contains("DispatchQueue.main.async"),
            "Quit confirmation must not visibly jump into place after the first paint."
        )
    }

    func test_quitConfirmationPinsOpeningVisibleFrameAcrossOrdering() throws {
        let source = try quitConfirmationSource()

        XCTAssertTrue(
            source.contains("let openingVisibleFrame = SidekeyWindowChrome.preferredVisibleFrame(for: window)"),
            "Quit confirmation should resolve the target visible frame once before ordering."
        )
        XCTAssertTrue(
            source.contains("SidekeyWindowChrome.center(window, inVisibleFrame: openingVisibleFrame)"),
            "Quit confirmation should center against the pinned visible frame before and after ordering."
        )
    }

    func test_quitConfirmationPinsContentSizeBeforeFirstShow() throws {
        let source = try quitConfirmationSource()

        XCTAssertTrue(
            source.contains("private static let contentSize = NSSize(width: 380, height: 196)"),
            "Quit confirmation should keep one explicit content size for creation and first display."
        )

        guard let hostingRange = source.range(of: "window.contentViewController = NSHostingController") else {
            XCTFail("Quit confirmation should install a SwiftUI hosting controller.")
            return
        }
        let afterHosting = source[hostingRange.upperBound...]

        XCTAssertTrue(
            afterHosting.contains("window.setContentSize(Self.contentSize)"),
            "Assigning NSHostingController can temporarily collapse the first window to zero size; pin it before show()."
        )
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
        throw NSError(domain: "SidekeyQuitConfirmationControllerTests", code: 1)
    }

    private func quitConfirmationSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("WindowChrome")
            .appendingPathComponent("SidekeyQuitConfirmationController.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
