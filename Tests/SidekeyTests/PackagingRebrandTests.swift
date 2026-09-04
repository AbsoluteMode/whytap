import XCTest

final class PackagingRebrandTests: XCTestCase {
    func test_buildDmgUsesWhytapBundleNamesButKeepsStableIdentity() throws {
        let source = try readProjectFile("scripts/build-dmg.sh")

        XCTAssertTrue(source.contains(#"EXECUTABLE_NAME="Sidekey""#))
        XCTAssertTrue(source.contains(#"BUNDLE_ID="com.rootwise.sidekey.beta""#))
        XCTAssertTrue(source.contains(#"BUNDLE_ID="com.rootwise.sidekey""#))

        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Whytap-Beta""#))
        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Whytap""#))
        XCTAssertFalse(source.contains(#"APP_BUNDLE_NAME="Sidekey-Beta""#))
        XCTAssertFalse(source.contains(#"APP_BUNDLE_NAME="Sidekey""#))
    }

    func test_userReleaseScriptUsesWhytapArtifactNames() throws {
        // The release artifact names used to be passed by the GitHub Actions
        // workflow (.github/workflows/release.yml). That CI build is gone —
        // releases are cut locally via scripts/user-release.sh, which now owns
        // the flavor → APP_BUNDLE_NAME mapping. The rebrand invariant
        // (artifacts are "Whytap", never "Sidekey") lives there now.
        let source = try readProjectFile("scripts/user-release.sh")

        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Whytap""#))
        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Whytap-Beta""#))
        XCTAssertFalse(source.contains(#"APP_BUNDLE_NAME="Sidekey""#))
        XCTAssertFalse(source.contains(#"APP_BUNDLE_NAME="Sidekey-Beta""#))
    }

    func test_uploadReleasePublishesToGitHubReleasesWithLatestAlias() throws {
        // Releases live on GitHub Releases: the versioned DMG, a stable
        // `<Bundle>-latest.dmg` alias and the signed appcast are assets of
        // the release. No object storage, no legacy Sidekey aliases.
        let source = try readProjectFile("scripts/upload-release.sh")

        XCTAssertTrue(source.contains("gh release create"))
        XCTAssertTrue(source.contains("generate_appcast"))
        XCTAssertTrue(source.contains(#"LATEST_FILENAME="${APP_BUNDLE_NAME}-latest.dmg""#))
        XCTAssertTrue(source.contains("releases/latest/download/appcast.xml"))
        XCTAssertFalse(source.contains("Sidekey-latest.dmg"))
        XCTAssertFalse(source.contains("aws s3"))
        XCTAssertFalse(source.contains("updates.whytap.ai"))
    }

    func test_devRunUsesWhytapDevBundleAndCleansOldSidekeyBundles() throws {
        let source = try readProjectFile("scripts/dev-run.sh")

        XCTAssertTrue(source.contains(#"APP_NAME="Sidekey""#))
        XCTAssertTrue(source.contains(#"EXECUTABLE_NAME="Sidekey""#))
        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Whytap-Beta-dev.app""#))
        XCTAssertTrue(source.contains("build/Sidekey-Beta-dev.app"))
    }

    /// Regression guard for the silent system-audio failure (June 2026): the
    /// CoreAudio process tap that records the other meeting participants is
    /// gated by the TCC "System Audio Recording" permission, and macOS only
    /// shows that permission prompt when `NSAudioCaptureUsageDescription` is
    /// present in Info.plist. When the key is missing the tap still starts
    /// without any error and delivers all-zero buffers forever — meetings
    /// lose the other party with no diagnostic. The key was lost once during
    /// the SCStream → process-tap migration; never let it drop again.
    func test_infoPlistDeclaresSystemAudioCaptureUsageForMeetingTap() throws {
        let source = try readProjectFile("Resources/Info.plist.template")

        XCTAssertTrue(
            source.contains("<key>NSAudioCaptureUsageDescription</key>"),
            "NSAudioCaptureUsageDescription is required for the meeting system-audio tap TCC prompt; without it the tap silently records zeros"
        )
        // The prompt also needs a human-readable, non-placeholder reason.
        let pattern = "<key>NSAudioCaptureUsageDescription</key>\\s*<string>[^<]{10,}</string>"
        XCTAssertNotNil(
            source.range(of: pattern, options: .regularExpression),
            "NSAudioCaptureUsageDescription must carry a non-empty usage string"
        )
    }

    func test_releaseBuildDoesNotClaimRestrictedKeychainEntitlementsWithoutProvisioningProfile() throws {
        let source = try readProjectFile("scripts/build-dmg.sh")

        XCTAssertFalse(source.contains("RELEASE_ENTITLEMENTS"))
        XCTAssertFalse(source.contains("com.apple.developer.team-identifier"))
        XCTAssertFalse(source.contains("com.apple.application-identifier"))
        XCTAssertFalse(source.contains("${TEAM_ID}.${BUNDLE_ID}"))
    }

    func test_readmePointsNewInstallsAtWhytapLatestDmg() throws {
        let source = try readProjectFile("README.md")

        XCTAssertTrue(source.contains("Whytap-latest.dmg"))
        XCTAssertFalse(source.contains("Sidekey-latest.dmg"))
    }

    private func readProjectFile(_ relativePath: String) throws -> String {
        let url = try projectRoot().appendingPathComponent(relativePath)
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
        throw NSError(domain: "PackagingRebrandTests", code: 1)
    }
}
