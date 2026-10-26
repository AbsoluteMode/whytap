import AVFoundation
import XCTest
@testable import Sidekey

@MainActor
final class ScreenRecordingRemovalTests: XCTestCase {
    func testScreenRecordingIsNotRequiredForReadyState() {
        let snapshot = PermissionsHelper.Snapshot(
            accessibilityGranted: true,
            microphoneStatus: .authorized
        )

        XCTAssertTrue(
            snapshot.allRequiredGranted,
            "Screen Recording must not block launch; Sidekey no longer samples the screen for the orb palette."
        )
    }

    func testAppLaunchDoesNotStartLiveScreenCaptureForOrbLuminance() throws {
        let source = try loadSource(named: "AppDelegate.swift")

        XCTAssertFalse(source.contains("startLiveLuminanceIfPermitted()"))
        XCTAssertFalse(source.contains("enterLiveMode()"))
        XCTAssertFalse(source.contains("Screen Recording (orb adaptive palette)"))
    }

    func testFloatingDotPanelDoesNotStartScreenCaptureFromOrbPhase() throws {
        let source = try loadSource(named: "FloatingDotPanel.swift")

        XCTAssertFalse(source.contains("await luminance.start()"))
        XCTAssertFalse(source.contains("await luminance.stop()"))
    }

    func testPermissionsSurfaceOffersExplicitScreenshotAccess() throws {
        let settings = try loadSource(named: "SettingsPermissionsView.swift")

        XCTAssertTrue(settings.contains("title: \"Screen Recording\""))
        XCTAssertTrue(settings.contains("await viewModel.requestScreenRecording()"))
    }

    func testOnlyExplicitScreenshotAndSettingsEntriesMayRequestScreenRecording() throws {
        let forbidden = [
            "CGRequestScreenCaptureAccess",
            "ScreenCapture.hasPermission",
            "/usr/sbin/screencapture"
        ]
        let offenders = try appSourceFiles().compactMap { url -> String? in
            // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
            // The user explicitly added screenshots; launch/orb/meetings still must not prompt.
            if url.path.hasSuffix("/Screenshots/ScreenshotCoordinator.swift") { return nil }
            // WHY: .project-docs/decisions/2026-10-22-agent-answers-and-screen.md
            // Requested agent frames use the same app-owned TCC boundary.
            if url.path.hasSuffix("/Agent/AgentScreenCapture.swift") { return nil }
            if url.lastPathComponent == "PermissionsHelper.swift" { return nil }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let hits = forbidden.filter { source.contains($0) }
            guard !hits.isEmpty else { return nil }
            return "\(url.lastPathComponent): \(hits.joined(separator: ", "))"
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Only explicit Screenshot or Settings actions may request Screen Recording: \(offenders.joined(separator: "; "))"
        )
    }

    func testOnlyExplicitCaptureAndSettingsPermissionEntriesMayUseScreenCaptureKit() throws {
        let forbidden = [
            "import ScreenCaptureKit",
            "SCStream",
            "SCShareableContent",
            "SCStreamOutput",
            "SCStreamConfiguration"
        ]
        let offenders = try appSourceFiles().compactMap { url -> String? in
            if url.path.hasSuffix("/Screenshots/ScreenshotCoordinator.swift") { return nil }
            if url.path.hasSuffix("/Agent/AgentScreenCapture.swift") { return nil }
            if url.lastPathComponent == "PermissionsHelper.swift" { return nil }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let hits = forbidden.filter { source.contains($0) }
            guard !hits.isEmpty else { return nil }
            return "\(url.lastPathComponent): \(hits.joined(separator: ", "))"
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Meeting audio must not rely on ScreenCaptureKit/SCStream: \(offenders.joined(separator: "; "))"
        )
    }

    func testSettingsPermissionRequestDoesNotCaptureImagesOrStartStreams() throws {
        let source = try loadSource(named: "PermissionsHelper.swift")
        XCTAssertFalse(source.contains("SCScreenshotManager"))
        XCTAssertFalse(source.contains("SCStream("))
        XCTAssertFalse(source.contains(".startCapture("))
    }

    func testScreenshotEntryUsesStillImagesAndDoesNotStartARecordingStream() throws {
        let file = try XCTUnwrap(try appSourceFiles().first { $0.path.hasSuffix("/Screenshots/ScreenshotCoordinator.swift") })
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("SCScreenshotManager.captureImage("))
        XCTAssertTrue(source.contains("func start()"))
        XCTAssertFalse(source.contains("SCStream("))
        XCTAssertFalse(source.contains(".startCapture("))
        XCTAssertFalse(source.contains("SCStreamOutput"))
    }

    func testAgentScreenToolUsesStillImagesOnlyAfterInvocation() throws {
        let file = try XCTUnwrap(try appSourceFiles().first { $0.path.hasSuffix("/Agent/AgentScreenCapture.swift") })
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("SCScreenshotManager.captureImage("))
        XCTAssertTrue(source.contains("func handle("))
        XCTAssertTrue(source.contains("guard permission()"))
        XCTAssertFalse(source.contains("SCStream("))
        XCTAssertFalse(source.contains(".startCapture("))
        XCTAssertFalse(source.contains("SCStreamOutput"))
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

        return roots.flatMap { root in
            [
                root.appendingPathComponent("Sources").appendingPathComponent("Sidekey").appendingPathComponent(filename),
                root.appendingPathComponent("Sources").appendingPathComponent("Sidekey").appendingPathComponent("Settings").appendingPathComponent(filename),
                root.appendingPathComponent("Sources").appendingPathComponent("Sidekey").appendingPathComponent("WindowChrome").appendingPathComponent(filename)
            ]
        }
    }

    private func appSourceFiles() throws -> [URL] {
        let roots = candidateSourceRoots()
        let manager = FileManager.default
        for root in roots {
            let sourceRoot = root.appendingPathComponent("Sources").appendingPathComponent("Sidekey")
            guard manager.fileExists(atPath: sourceRoot.path) else { continue }
            let enumerator = manager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let urls = (enumerator?.compactMap { $0 as? URL } ?? []).filter { url in
                url.pathExtension == "swift"
            }
            if !urls.isEmpty { return urls }
        }
        throw XCTSkip("Sidekey source root not reachable from test bundle.")
    }

    private func candidateSourceRoots() -> [URL] {
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
        return roots
    }
}
