import XCTest

/// Contract test pinning the local release build to the macOS 26 (Tahoe) SDK.
///
/// WHY: on macOS 26 AppKit applies the Liquid Glass material pipeline only to
/// binaries linked against the macOS 26 SDK. A DMG built with Xcode 16.x links
/// the macOS 15 SDK and renders legacy Sequoia materials on Tahoe, which made
/// the island's glass look completely different on a teammate's fresh install
/// vs local dev builds (Xcode 26.4.1).
///
/// This used to run on a GitHub `macos-26` runner with an explicit
/// `xcode-select -s /Applications/Xcode_26` step, and the contract pinned that
/// workflow. Releases are now cut locally (`scripts/user-release.sh` ->
/// `scripts/build-dmg.sh`) with no CI runner to pin, so the SDK floor is
/// enforced by a preflight guard inside `build-dmg.sh` instead. This test pins
/// that guard so the Liquid Glass regression can never silently return.
final class ReleaseToolchainContractTests: XCTestCase {
    func test_releaseBuildGuardsAgainstPreTahoeSDK() throws {
        let source = try readProjectFile("scripts/build-dmg.sh")

        XCTAssertTrue(
            source.contains("xcrun --sdk macosx --show-sdk-version"),
            "build-dmg.sh must read the active macOS SDK version to gate the toolchain"
        )
        // Pin the exact comparison, not just the substring "-lt 26": an inverted
        // guard like `[ ! "${SDK_MAJOR}" -lt 26 ]` still contains "-lt 26" yet
        // would accept a pre-Tahoe SDK. The precise expression pins the
        // direction so that regression cannot pass green.
        XCTAssertTrue(
            source.contains(#"[ "${SDK_MAJOR}" -lt 26 ]"#),
            "build-dmg.sh must apply -lt 26 to SDK_MAJOR directly (not inverted), else an older SDK links the macOS 15 SDK → legacy (pre-Liquid Glass) materials"
        )
        // Match the operator-facing echo specifically (it carries `sudo` + `.app`),
        // not the WHY comment above the guard which also mentions xcode-select.
        XCTAssertTrue(
            source.contains("sudo xcode-select -s /Applications/Xcode_26.app"),
            "the guard's operator-facing message must tell the operator how to select an Xcode 26.x toolchain"
        )
    }

    private func readProjectFile(_ relativePath: String) throws -> String {
        let root = try projectRoot()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
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
        throw NSError(domain: "ReleaseToolchainContractTests", code: 1)
    }
}
