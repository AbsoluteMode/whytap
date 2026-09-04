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

    func testPermissionsSurfacesDoNotAskForScreenRecording() throws {
        let onboarding = try loadSource(named: "OnboardingWindowController.swift")
        let settings = try loadSource(named: "SettingsPermissionsView.swift")

        XCTAssertFalse(onboarding.contains("title: \"Screen Recording\""))
        XCTAssertFalse(onboarding.contains("requestScreenRecording"))
        XCTAssertFalse(settings.contains("title: \"Screen Recording\""))
        XCTAssertFalse(settings.contains("requestScreenRecording"))
    }

    func testNoScreenRecordingPromptCodeRemainsInAppSources() throws {
        let forbidden = [
            "CGRequestScreenCaptureAccess",
            "ScreenCapture.hasPermission",
            "/usr/sbin/screencapture"
        ]
        let offenders = try appSourceFiles().compactMap { url -> String? in
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let hits = forbidden.filter { source.contains($0) }
            guard !hits.isEmpty else { return nil }
            return "\(url.lastPathComponent): \(hits.joined(separator: ", "))"
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Screen Recording prompt/screenshot code should not remain in app sources: \(offenders.joined(separator: "; "))"
        )
    }

    func testNoScreenCaptureKitTransportRemainsInAppSources() throws {
        let forbidden = [
            "import ScreenCaptureKit",
            "SCStream",
            "SCShareableContent",
            "SCStreamOutput",
            "SCStreamConfiguration"
        ]
        let offenders = try appSourceFiles().compactMap { url -> String? in
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
