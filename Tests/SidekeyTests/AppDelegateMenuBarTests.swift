import XCTest
@testable import Sidekey

@MainActor
final class AppDelegateMenuBarTests: XCTestCase {
    func test_appDelegateDoesNotCreateSystemMenuBarStatusItem() throws {
        let source = try loadSource(named: "AppDelegate.swift")

        XCTAssertFalse(source.contains("NSStatusBar.system.statusItem"))
        XCTAssertFalse(source.contains("installStatusBarMenu()"))
        XCTAssertTrue(source.contains("IslandPanel.shared.show()"))
    }

    private func loadSource(named filename: String) throws -> String {
        let candidates = candidateSourceURLs(for: filename)
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let source = String(data: data, encoding: .utf8) {
                return source
            }
        }
        throw XCTSkip("Source file \(filename) not reachable from test bundle.")
    }

    private func candidateSourceURLs(for filename: String) -> [URL] {
        let env = ProcessInfo.processInfo.environment
        var roots: [URL] = []
        if let srcroot = env["SRCROOT"] { roots.append(URL(fileURLWithPath: srcroot)) }
        if let pkgRoot = env["PACKAGE_PATH"] { roots.append(URL(fileURLWithPath: pkgRoot)) }

        let thisFile = URL(fileURLWithPath: #filePath)
        var cursor = thisFile.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent("Package.swift").path) {
                roots.append(cursor)
                break
            }
            cursor.deleteLastPathComponent()
        }

        return roots.map { root in
            root.appendingPathComponent("Sources")
                .appendingPathComponent("Sidekey")
                .appendingPathComponent(filename)
        }
    }
}
