import XCTest
@testable import Sidekey

/// Whytap is fully local: no sign-in, no Whytap servers, no metering. This
/// source-inspection guard fails the build the moment a cloud symbol, host
/// name, or billing concept reappears anywhere under `Sources/`. Modelled on
/// `ScreenRecordingRemovalTests`.
final class CloudRemovalTests: XCTestCase {
    /// Literals that must never appear in app sources again. Host names cover
    /// the retired API and auth services (prod and staging); type names cover
    /// the retired backend client, telemetry, tiering, hub STT adapter,
    /// server-synced preferences, cloud meetings pipeline, and session refresh.
    private static let forbidden = [
        "api.whytap.ai",
        "auth.whytap.ai",
        "api-staging.whytap.ai",
        "auth-staging.whytap.ai",
        "BackendClient",
        "EventTracker",
        "UsageCache",
        "UserTier",
        "WhytapHubAdapter",
        "PreferencesAPIClient",
        "MeetingsBackendClient",
        "UploadQueue",
        "SessionRefreshing",
        "streamingHandshakeJWT",
        "consumerBilling",
    ]

    func testNoCloudReferencesRemainInAppSources() throws {
        let offenders = try appSourceFiles().compactMap { url -> String? in
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let hits = Self.forbidden.filter { source.contains($0) }
            guard !hits.isEmpty else { return nil }
            return "\(url.lastPathComponent): \(hits.joined(separator: ", "))"
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Cloud references must not remain in app sources: \(offenders.joined(separator: "; "))"
        )
    }

    func testBuildConfigKeepsOnlyLocalEndpoints() {
        // The update feed and the project page are the only URLs the app
        // knows about; both live on GitHub, are read-only and carry no user
        // data.
        XCTAssertEqual(BuildConfig.appcastURL.host, "github.com")
        XCTAssertTrue(BuildConfig.appcastURL.path.hasSuffix("/appcast.xml"))
        XCTAssertEqual(BuildConfig.landingURL.host, "github.com")
    }

    /// Agent sources reach only servers the user configured. The only
    /// addresses in that code are GitHub's MCP server and the token pages the
    /// GitHub and Jira tiles open. WHY: .project-docs/decisions/2026-11-26-agent-sources.md
    func testAgentSourcesContainNoOtherHosts() throws {
        let allowed: Set<String> = ["api.githubcopilot.com", "github.com", "id.atlassian.com", "docs.github.com",
                                    "your-team.atlassian.net", "example.com"]
        let expression = try NSRegularExpression(pattern: #"https?://([A-Za-z0-9.-]+)"#)
        let files = try appSourceFiles().filter {
            $0.path.contains("/Assistant/") || $0.lastPathComponent == "NativeAgentSources.swift"
                || $0.lastPathComponent == "AddSourceSheet.swift" || $0.lastPathComponent == "AgentSourcesSettings.swift"
        }
        XCTAssertFalse(files.isEmpty)
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let host = (source as NSString).substring(with: match.range(at: 1))
                XCTAssertTrue(allowed.contains(host) || host == "localhost" || host == "127.0.0.1",
                              "\(url.lastPathComponent): \(host)")
            }
        }
    }

    /// Every `.swift` file under `Sources/` (all targets), not just the app
    /// library, so the preview executable cannot drift either.
    private func appSourceFiles() throws -> [URL] {
        let roots = candidateSourceRoots()
        let manager = FileManager.default
        for root in roots {
            let sourceRoot = root.appendingPathComponent("Sources")
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
        throw XCTSkip("Sources root not reachable from test bundle.")
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
