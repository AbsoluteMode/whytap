import XCTest

final class SidekeyAuroraWindowTests: XCTestCase {
    func test_auroraWindowDoesNotDrawExternalFrame() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("WindowChrome")
            .appendingPathComponent("SidekeyAuroraWindow.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private let haloPadding: CGFloat = 0"))
        XCTAssertFalse(source.contains("SidekeyHaloBackground()"))
        XCTAssertFalse(source.contains(".overlay(gradientBorder)"))
        XCTAssertFalse(source.contains(".overlay(topHighlight)"))
        XCTAssertFalse(source.contains("private var gradientBorder"))
        XCTAssertFalse(source.contains("private var topHighlight"))
        XCTAssertFalse(source.contains(".shadow(color:"))
    }

    func test_auroraWindowExtendsUnderSystemTitlebar() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("WindowChrome")
            .appendingPathComponent("SidekeyAuroraWindow.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(".ignoresSafeArea()"))
        XCTAssertFalse(source.contains("SidekeyWindowButtonHost"))
        XCTAssertFalse(source.contains("performClose(nil)"))
        XCTAssertFalse(source.contains("miniaturize(nil)"))
        XCTAssertFalse(source.contains("zoom(nil)"))
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
        throw NSError(domain: "SidekeyAuroraWindowTests", code: 1)
    }
}
