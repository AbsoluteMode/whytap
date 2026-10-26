import CryptoKit
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
        // Releases live on GitHub Releases: one `<Bundle>-latest.dmg`
        // and the signed appcast are assets of
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

    func test_devRunUsesWhytapDevBundleWithoutDeletingLegacyCopies() throws {
        let source = try readProjectFile("scripts/dev-run.sh")

        XCTAssertTrue(source.contains(#"APP_NAME="Sidekey""#))
        XCTAssertTrue(source.contains(#"EXECUTABLE_NAME="Sidekey""#))
        XCTAssertTrue(source.contains(#"APP_BUNDLE_NAME="Whytap-Beta-dev.app""#))
        XCTAssertFalse(source.contains("stop_conflicting_sidekey_processes"))
    }

    /// The Case helper (`Contents/Helpers/whytap`) must ship in every bundle and
    /// be signed before the app: the broker trusts it by cdhash and the CLI
    /// reads its host bundle ID from `Contents/Info.plist` next to it.
    func test_caseHelperIsBuiltCopiedAndSignedBeforeTheApp() throws {
        let dmg = try readProjectFile("scripts/build-dmg.sh")
        let dev = try readProjectFile("scripts/dev-run.sh")

        for (name, source) in [("build-dmg.sh", dmg), ("dev-run.sh", dev)] {
            XCTAssertTrue(source.contains("--product whytap"), "\(name) must build the helper")
            XCTAssertTrue(source.contains(#""${APP_BUNDLE}/Contents/Helpers/whytap""#),
                          "\(name) must place the helper at Contents/Helpers/whytap")
            let helperSign = try XCTUnwrap(
                source.range(of: #"--options runtime"#, options: [],
                             range: try XCTUnwrap(source.range(of: "Signing whytap helper")
                                ?? source.range(of: "Code signing whytap helper")).lowerBound..<source.endIndex),
                "\(name) must sign the helper")
            let appSign = try XCTUnwrap(source.range(of: #"--entitlements "#, options: .backwards))
            XCTAssertLessThan(helperSign.lowerBound, appSign.lowerBound,
                              "\(name) must sign the helper before the app bundle")
        }
        XCTAssertTrue(dmg.contains("--arch arm64 --product whytap"))
        XCTAssertTrue(dmg.contains("--arch x86_64 --product whytap"))
        XCTAssertTrue(dmg.contains(#"-output "${BUILD_DIR}/whytap""#), "helper must be lipo'd universal")
        XCTAssertTrue(dmg.contains(#""Contents/Helpers/whytap""#), "release verification must cover the helper signature")
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

    /// The offline preflight reports the committed team without touching the
    /// keychain, so it also runs on Macs without the Developer ID certificate.
    /// A build alone, like the builder's local refresh, is not notarized.
    func test_communityPreflightNeedsNoCredentialsOrNotarization() throws {
        for (script, arguments) in [("scripts/build-dmg.sh", ["--preflight-only"]),
                                    ("scripts/user-release.sh", ["--build-only", "--preflight-only"])] {
            let result = try runScript(try projectRoot().appendingPathComponent(script),
                arguments: arguments,
                environment: ["PATH": "/usr/bin:/bin", "FLAVOR": "prod", "BUILD_VERSION": "42"])
            XCTAssertEqual(result.status, 0, result.output)
            let lastLine = try XCTUnwrap(result.output.split(separator: "\n").last)
            let data = Data(lastLine.utf8)
            let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(plan["distribution"] as? String, "community")
            XCTAssertEqual(plan["code_signing"] as? String, "team:UVBKCN5PPV")
            XCTAssertEqual(plan["requires_apple_developer"] as? Bool, true)
            XCTAssertEqual(plan["requires_notarization"] as? Bool, false)
            XCTAssertEqual(plan["notarization"] as? String, "none")
            XCTAssertEqual(plan["architectures"] as? [String], ["arm64", "x86_64"])
            XCTAssertEqual(plan["bundle_id"] as? String, "com.rootwise.sidekey")
        }
    }

    func test_communityBuildReachesCompilerWithoutAppleTools() throws {
        let run = try runBuildFixture()
        XCTAssertEqual(run.result.status, 64, run.result.output)
        XCTAssertEqual(run.calls, "compiler\n")
        XCTAssertTrue(run.result.output.contains("Code signing: adhoc"), run.result.output)
    }

    // WHY: .project-docs/decisions/2026-10-19-community-signing-identity.md
    func test_communityCertificateBuildChecksItsKeyBeforeCompiling() throws {
        let identities = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: identities) }
        let identity = try makeSigningIdentity(in: identities, name: "release")
        let other = try makeSigningIdentity(in: identities, name: "other")

        let missing = try runBuildFixture(certificate: identity.certificate)
        XCTAssertEqual(missing.result.status, 1, missing.result.output)
        XCTAssertTrue(missing.result.output.contains("EXODIA_COMMUNITY_SIGNING_KEY"), missing.result.output)
        XCTAssertNil(missing.calls, missing.result.output)

        let mismatched = try runBuildFixture(certificate: identity.certificate,
            environment: ["EXODIA_COMMUNITY_SIGNING_KEY_FILE": other.key.path])
        XCTAssertEqual(mismatched.result.status, 1, mismatched.result.output)
        XCTAssertTrue(mismatched.result.output.contains("does not match"), mismatched.result.output)
        XCTAssertNil(mismatched.calls, mismatched.result.output)

        // The keychain is prepared only after compiling, so no security call precedes it.
        let matching = try runBuildFixture(certificate: identity.certificate,
            environment: ["EXODIA_COMMUNITY_SIGNING_KEY": try String(contentsOf: identity.key, encoding: .utf8)])
        XCTAssertEqual(matching.result.status, 64, matching.result.output)
        XCTAssertEqual(matching.calls, "compiler\n")
        XCTAssertTrue(matching.result.output.contains("Code signing: certificate:" + identity.sha1),
                      matching.result.output)

        let optedOut = try runBuildFixture(certificate: identity.certificate,
            environment: ["EXODIA_COMMUNITY_SIGNING": "adhoc"])
        XCTAssertEqual(optedOut.result.status, 64, optedOut.result.output)
        XCTAssertEqual(optedOut.calls, "compiler\n")
        XCTAssertTrue(optedOut.result.output.contains("Code signing: adhoc"), optedOut.result.output)
    }

    func test_communityPreflightReportsTheCommittedCertificate() throws {
        let identities = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: identities) }
        let identity = try makeSigningIdentity(in: identities, name: "release")
        let run = try runBuildFixture(certificate: identity.certificate, arguments: ["--preflight-only"])
        XCTAssertEqual(run.result.status, 0, run.result.output)
        XCTAssertNil(run.calls, run.result.output)
        let lastLine = try XCTUnwrap(run.result.output.split(separator: "\n").last)
        let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any])
        XCTAssertEqual(plan["code_signing"] as? String, "certificate:" + identity.sha1)
        XCTAssertEqual(plan["signing_certificate_sha1"] as? String, identity.sha1)
        XCTAssertEqual(plan["signing_key_configured"] as? Bool, false)
        XCTAssertEqual(plan["requires_apple_developer"] as? Bool, false)
    }

    // WHY: .project-docs/decisions/2026-10-21-developer-id-team-signing.md
    func test_teamBuildFindsItsDeveloperIDBeforeCompiling() throws {
        let team = "TEAMID1234"
        let identity = "0123456789ABCDEF0123456789ABCDEF01234567"
        let renewal = "FEDCBA9876543210FEDCBA9876543210FEDCBA98"
        func listing(_ identities: [(hash: String, team: String)]) -> String {
            identities.enumerated().map { index, item in
                "  \(index + 1)) \(item.hash) \"Developer ID Application: Test Person (\(item.team))\""
            }.joined(separator: "\n") + "\n     \(identities.count) valid identities found\n"
        }

        let otherTeam = try runBuildFixture(teamID: team, securityOutput: listing([(renewal, "OTHERTEAM1")]))
        XCTAssertEqual(otherTeam.result.status, 1, otherTeam.result.output)
        XCTAssertTrue(otherTeam.result.output.contains("no valid Developer ID Application certificate of team " + team),
                      otherTeam.result.output)
        XCTAssertEqual(otherTeam.calls, "identity-lookup\n")

        let found = try runBuildFixture(teamID: team, securityOutput: listing([(identity, team)]))
        XCTAssertEqual(found.result.status, 64, found.result.output)
        XCTAssertEqual(found.calls, "identity-lookup\ncompiler\n")
        XCTAssertTrue(found.result.output.contains("Code signing: team:" + team), found.result.output)
        XCTAssertTrue(found.result.output.contains("Developer ID identity: " + identity), found.result.output)

        // After a renewal both certificates stay valid until the old one expires.
        let renewed = listing([(identity, team), (renewal, team)])
        let ambiguous = try runBuildFixture(teamID: team, securityOutput: renewed)
        XCTAssertEqual(ambiguous.result.status, 1, ambiguous.result.output)
        XCTAssertTrue(ambiguous.result.output.contains("EXODIA_DEVELOPER_ID_IDENTITY"), ambiguous.result.output)
        XCTAssertEqual(ambiguous.calls, "identity-lookup\n")

        let chosen = try runBuildFixture(teamID: team, securityOutput: renewed,
            environment: ["EXODIA_DEVELOPER_ID_IDENTITY": renewal.lowercased()])
        XCTAssertEqual(chosen.result.status, 64, chosen.result.output)
        XCTAssertTrue(chosen.result.output.contains("Developer ID identity: " + renewal), chosen.result.output)

        let unknown = try runBuildFixture(teamID: team, securityOutput: renewed,
            environment: ["EXODIA_DEVELOPER_ID_IDENTITY": String(repeating: "A", count: 40)])
        XCTAssertEqual(unknown.result.status, 1, unknown.result.output)
        XCTAssertNil(unknown.calls?.range(of: "compiler"), unknown.result.output)

        let optedOut = try runBuildFixture(teamID: team, environment: ["EXODIA_COMMUNITY_SIGNING": "adhoc"])
        XCTAssertEqual(optedOut.result.status, 64, optedOut.result.output)
        XCTAssertEqual(optedOut.calls, "compiler\n")
        XCTAssertTrue(optedOut.result.output.contains("Code signing: adhoc"), optedOut.result.output)
    }

    /// The committed team takes precedence over the community certificate, and
    /// its build needs neither the community key nor any keychain access to plan.
    func test_teamPreflightReportsTheCommittedTeam() throws {
        let identities = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: identities) }
        let identity = try makeSigningIdentity(in: identities, name: "release")
        let run = try runBuildFixture(certificate: identity.certificate, teamID: "TEAMID1234",
                                      arguments: ["--preflight-only"])
        XCTAssertEqual(run.result.status, 0, run.result.output)
        XCTAssertNil(run.calls, run.result.output)
        let lastLine = try XCTUnwrap(run.result.output.split(separator: "\n").last)
        let plan = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any])
        XCTAssertEqual(plan["code_signing"] as? String, "team:TEAMID1234")
        XCTAssertEqual(plan["signing_team_id"] as? String, "TEAMID1234")
        XCTAssertNil(plan["signing_certificate_sha1"] as? String)
        XCTAssertEqual(plan["requires_apple_developer"] as? Bool, true)
        XCTAssertEqual(plan["requires_notarization"] as? Bool, false)

        let invalid = try runBuildFixture(teamID: "not-a-team", arguments: ["--preflight-only"])
        XCTAssertEqual(invalid.result.status, 1, invalid.result.output)
        XCTAssertTrue(invalid.result.output.contains("10-character Apple team ID"), invalid.result.output)
    }

    /// Keychain items and macOS privacy grants follow the team's designated
    /// requirement and keychain partition. Another team makes every install
    /// approve each stored key and grant its permissions again.
    func test_developerIDTeamIsPinned() throws {
        let team = try readProjectFile("Resources/developer-id-team.txt")
        XCTAssertEqual(team, "UVBKCN5PPV\n",
                       "A new team makes every install approve its keychain items and macOS permissions again")
    }

    /// Every community build's designated requirement pins this certificate's
    /// SHA-1 and macOS privacy grants follow that requirement. Another
    /// certificate makes every install grant Microphone and System Audio
    /// Recording again, so replacing it must be a deliberate rotation.
    func test_communitySigningCertificateIsPinned() throws {
        let pem = try readProjectFile("Resources/community-signing-certificate.pem")
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: body))
        let sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sha1, "39da363652f6df4b52ac950998e16c98fd39bc6b",
                       "A new community certificate makes every install grant its macOS permissions again; rotate only for a leaked key")
    }

    /// `.gitignore` excludes `*.pem` as signing material, and the provenance check
    /// lists untracked but not ignored files. An ignored certificate would let a
    /// build sign with a file outside the release commit while a fresh clone signs
    /// ad hoc.
    func test_communitySigningCertificateIsNotIgnored() throws {
        let result = try runTool(URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", try projectRoot().path, "check-ignore", "--no-index", "-q",
                        "Resources/community-signing-certificate.pem"],
            environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
        if result.status == 128 {
            throw XCTSkip("not a Git checkout")
        }
        XCTAssertEqual(result.status, 1, "Git ignores Resources/community-signing-certificate.pem: \(result.output)")
    }

    func test_publishingRunRefusesLocalSigningOverrides() throws {
        for override in [["EXODIA_COMMUNITY_SIGNING": "adhoc"],
                         ["EXODIA_COMMUNITY_SIGNING_CERTIFICATE_FILE": "/nonexistent/test.pem"]] {
            let result = try runScript(try projectRoot().appendingPathComponent("scripts/user-release.sh"),
                environment: ["PATH": "/usr/bin:/bin", "FLAVOR": "prod"].merging(override) { $1 })
            XCTAssertEqual(result.status, 1, result.output)
            XCTAssertTrue(result.output.contains("are for local builds"), result.output)
        }
    }

    func test_developerIDPathRequiresExplicitLegacyOptIn() throws {
        let result = try runScript(try projectRoot().appendingPathComponent("scripts/build-dmg.sh"),
            arguments: ["--preflight-only"], environment: ["PATH": "/usr/bin:/bin",
                "EXODIA_LEGACY_SIGNED_RELEASE": "1", "BUILD_VERSION": "42"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("TEAM_ID"), result.output)
    }

    func test_publicationRejectsUnsignedAppcastBeforeUploading() throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for directory in ["scripts", "Resources", "build", "bin", ".build/mock"] {
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
        let root = try projectRoot()
        try FileManager.default.copyItem(at: root.appendingPathComponent("scripts/upload-release.sh"),
            to: temporary.appendingPathComponent("scripts/upload-release.sh"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("Resources/Info.plist.template"),
            to: temporary.appendingPathComponent("Resources/Info.plist.template"))
        try Data("test".utf8).write(to: temporary.appendingPathComponent("build/Whytap-9.9.9-build42.dmg"))
        let marker = temporary.appendingPathComponent("publication-attempt.txt")
        try executable(at: temporary.appendingPathComponent("bin/gh"), contents: #"""
        #!/bin/bash
        if [ "$1 $2" = "auth status" ]; then exit 0; fi
        if [ "$1 $2" = "release download" ]; then exit 1; fi
        if [ "$1 $2" = "release view" ] || [ "$1" = "api" ]; then exit 1; fi
        echo unexpected-upload > "$PROBE_MARKER"
        exit 74
        """#)
        try executable(at: temporary.appendingPathComponent(".build/mock/generate_appcast"), contents: #"""
        #!/bin/bash
        for staging in "$@"; do :; done
        cat > "$staging/appcast.xml" <<'XML'
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>42</sparkle:version><sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
        <enclosure length="4" url="https://github.com/AbsoluteMode/whytap/releases/download/v9.9.9/Whytap-9.9.9-build42.dmg" />
        </item></channel></rss>
        XML
        """#)
        try executable(at: temporary.appendingPathComponent(".build/mock/sign_update"), contents: #"""
        #!/bin/bash
        echo unexpected-verification > "$PROBE_MARKER"
        exit 75
        """#)
        try prepareProvenanceFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg")
        let result = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
            environment: ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                "FLAVOR": "prod", "APP_BUNDLE_NAME": "Whytap", "SHORT_VERSION": "9.9.9",
                "BUILD_VERSION": "42", "PROBE_MARKER": marker.path,
                "SPARKLE_ED_PRIVATE_KEY": Data(repeating: 0, count: 32).base64EncodedString()])
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("refusing publication"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), result.output)
    }

    func test_publicationRequiresTheCommittedSigningIdentity() throws {
        let identities = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: identities) }
        let identity = try makeSigningIdentity(in: identities, name: "release")
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for directory in ["scripts", "Resources", "build", "bin"] {
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
        let root = try projectRoot()
        for relative in ["scripts/upload-release.sh", "Resources/Info.plist.template"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(relative),
                to: temporary.appendingPathComponent(relative))
        }
        try FileManager.default.copyItem(at: identity.certificate,
            to: temporary.appendingPathComponent("Resources/community-signing-certificate.pem"))
        try Data("test".utf8).write(to: temporary.appendingPathComponent("build/Whytap-9.9.9-build42.dmg"))
        let marker = temporary.appendingPathComponent("publication-attempt.txt")
        try executable(at: temporary.appendingPathComponent("bin/gh"), contents: #"""
        #!/bin/bash
        if [ "$1 $2" = "auth status" ] || [ "$1 $2" = "release view" ]; then exit 0; fi
        echo unexpected-upload > "$PROBE_MARKER"
        exit 74
        """#)
        try prepareProvenanceFixture(temporary)
        let environment = ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                           "FLAVOR": "prod", "APP_BUNDLE_NAME": "Whytap", "SHORT_VERSION": "9.9.9",
                           "BUILD_VERSION": "42", "PROBE_MARKER": marker.path]

        XCTAssertNotEqual(try sealFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg",
                                          codeSigning: "certificate:ABC", expectSuccess: false), 0)
        try sealFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg", codeSigning: "adhoc")
        let adhoc = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
                                  environment: environment)
        XCTAssertNotEqual(adhoc.status, 0)
        XCTAssertTrue(adhoc.output.contains("archive code signing does not match"), adhoc.output)

        // The upload derives the same identity from the committed certificate,
        // passes provenance and stops only at the existing-release guard.
        try sealFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg",
                        codeSigning: "certificate:" + identity.sha1)
        let signed = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
                                   environment: environment)
        XCTAssertNotEqual(signed.status, 0)
        XCTAssertTrue(signed.output.contains("already exists; refusing to overwrite"), signed.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), signed.output)
    }

    func test_publicationRequiresTheCommittedTeam() throws {
        let identities = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: identities) }
        let identity = try makeSigningIdentity(in: identities, name: "release")
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for directory in ["scripts", "Resources", "build", "bin"] {
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
        let root = try projectRoot()
        for relative in ["scripts/upload-release.sh", "Resources/Info.plist.template"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(relative),
                to: temporary.appendingPathComponent(relative))
        }
        try FileManager.default.copyItem(at: identity.certificate,
            to: temporary.appendingPathComponent("Resources/community-signing-certificate.pem"))
        try "TEAMID1234\n".write(to: temporary.appendingPathComponent("Resources/developer-id-team.txt"),
                                 atomically: true, encoding: .utf8)
        try Data("test".utf8).write(to: temporary.appendingPathComponent("build/Whytap-9.9.9-build42.dmg"))
        let marker = temporary.appendingPathComponent("publication-attempt.txt")
        try executable(at: temporary.appendingPathComponent("bin/gh"), contents: #"""
        #!/bin/bash
        if [ "$1 $2" = "auth status" ] || [ "$1 $2" = "release view" ]; then exit 0; fi
        echo unexpected-upload > "$PROBE_MARKER"
        exit 74
        """#)
        try prepareProvenanceFixture(temporary)
        let environment = ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                           "FLAVOR": "prod", "APP_BUNDLE_NAME": "Whytap", "SHORT_VERSION": "9.9.9",
                           "BUILD_VERSION": "42", "PROBE_MARKER": marker.path]

        XCTAssertNotEqual(try sealFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg",
                                          codeSigning: "team:short", expectSuccess: false), 0)
        // An archive signed with the community certificate no longer matches.
        try sealFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg",
                        codeSigning: "certificate:" + identity.sha1)
        let community = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
                                      environment: environment)
        XCTAssertNotEqual(community.status, 0)
        XCTAssertTrue(community.output.contains("archive code signing does not match"), community.output)

        // A team release is published notarized; an unnotarized team archive
        // passes only with the explicit opt-out.
        try sealFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg", codeSigning: "team:TEAMID1234")
        let unnotarized = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
                                        environment: environment)
        XCTAssertNotEqual(unnotarized.status, 0)
        XCTAssertTrue(unnotarized.output.contains("archive notarization (none) does not match the requested release (notarized)"),
                      unnotarized.output)
        let signed = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
                                   environment: environment.merging(["EXODIA_NOTARIZE": "0"]) { $1 })
        XCTAssertNotEqual(signed.status, 0)
        XCTAssertTrue(signed.output.contains("publishing without Apple notarization"), signed.output)
        XCTAssertTrue(signed.output.contains("already exists; refusing to overwrite"), signed.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), signed.output)
    }

    func test_publicationRefusesExistingVersionBeforeKeysOrUpload() throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for directory in ["scripts", "Resources", "build", "bin"] {
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
        let root = try projectRoot()
        for relative in ["scripts/upload-release.sh", "Resources/Info.plist.template"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(relative),
                to: temporary.appendingPathComponent(relative))
        }
        try Data("test".utf8).write(to: temporary.appendingPathComponent("build/Whytap-9.9.9-build42.dmg"))
        let marker = temporary.appendingPathComponent("publication-attempt.txt")
        try executable(at: temporary.appendingPathComponent("bin/gh"), contents: #"""
        #!/bin/bash
        if [ "$1 $2" = "auth status" ] || [ "$1 $2" = "release view" ]; then exit 0; fi
        echo unexpected-upload > "$PROBE_MARKER"
        exit 74
        """#)
        try prepareProvenanceFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg")
        let result = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
            environment: ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                "FLAVOR": "prod", "APP_BUNDLE_NAME": "Whytap", "SHORT_VERSION": "9.9.9",
                "BUILD_VERSION": "42", "PROBE_MARKER": marker.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("already exists; refusing to overwrite"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), result.output)
    }

    // MARK: Apple notarization
    // WHY: docs/decisions/2026-10-21-notarized-releases.md

    /// A run that publishes a team build notarizes it; the key comes from Case.
    func test_publishingPreflightNotarizesTheTeamBuild() throws {
        let script = try projectRoot().appendingPathComponent("scripts/user-release.sh")
        let environment = ["PATH": "/usr/bin:/bin", "FLAVOR": "prod", "BUILD_VERSION": "42"]
        func plan(_ arguments: [String], _ extra: [String: String] = [:]) throws -> [String: Any] {
            let result = try runScript(script, arguments: arguments,
                                       environment: environment.merging(extra) { $1 })
            XCTAssertEqual(result.status, 0, result.output)
            let lastLine = try XCTUnwrap(result.output.split(separator: "\n").last)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any])
        }

        let publication = try plan(["--preflight-only"])
        XCTAssertEqual(publication["requires_notarization"] as? Bool, true)
        XCTAssertEqual(publication["notarization"] as? String, "notarized")
        XCTAssertEqual(publication["notarization_credentials"] as? String, "case:whytap")
        XCTAssertEqual(publication["notarization_keys"] as? [String],
                       ["ASC_API_KEY_ID", "ASC_API_KEY_ISSUER_ID", "ASC_API_KEY_P8"])
        XCTAssertEqual(publication["code_signing"] as? String, "team:UVBKCN5PPV")

        let optedOut = try plan(["--preflight-only"], ["EXODIA_NOTARIZE": "0"])
        XCTAssertEqual(optedOut["notarization"] as? String, "none")
        let requested = try plan(["--build-only", "--preflight-only"], ["EXODIA_NOTARIZE": "1"])
        XCTAssertEqual(requested["notarization"] as? String, "notarized")

        let invalid = try runScript(script, arguments: ["--preflight-only"],
                                    environment: environment.merging(["EXODIA_NOTARIZE": "yes"]) { $1 })
        XCTAssertEqual(invalid.status, 1, invalid.output)
        XCTAssertTrue(invalid.output.contains("EXODIA_NOTARIZE must be 0 or 1"), invalid.output)
    }

    /// Only Developer ID code can be notarized.
    func test_notarizationNeedsTheDeveloperIDTeam() throws {
        let adhoc = try runBuildFixture(arguments: ["--preflight-only"], environment: ["EXODIA_NOTARIZE": "1"])
        XCTAssertEqual(adhoc.result.status, 1, adhoc.result.output)
        XCTAssertTrue(adhoc.result.output.contains("cannot be notarized"), adhoc.result.output)
        XCTAssertNil(adhoc.calls, adhoc.result.output)

        let optedOut = try runBuildFixture(teamID: "TEAMID1234",
            environment: ["EXODIA_NOTARIZE": "1", "EXODIA_COMMUNITY_SIGNING": "adhoc"])
        XCTAssertEqual(optedOut.result.status, 1, optedOut.result.output)
        XCTAssertTrue(optedOut.result.output.contains("cannot be notarized"), optedOut.result.output)
        XCTAssertNil(optedOut.calls, optedOut.result.output)

        let invalid = try runBuildFixture(teamID: "TEAMID1234", environment: ["EXODIA_NOTARIZE": "yes"])
        XCTAssertEqual(invalid.result.status, 2, invalid.result.output)
        XCTAssertNil(invalid.calls, invalid.result.output)
    }

    /// Until the App Store Connect key is in Case, a notarized build stops
    /// before compiling and names exactly the missing keys. Only key names are read.
    func test_notarizedBuildNamesMissingCaseKeysBeforeCompiling() throws {
        let team = "TEAMID1234"
        let identities = "  1) 0123456789ABCDEF0123456789ABCDEF01234567 \"Developer ID Application: Test Person (\(team))\"\n"
            + "     1 valid identities found\n"
        let notarize = ["EXODIA_NOTARIZE": "1"]
        func listing(_ names: [String]) -> String {
            (["NAME                PROJECT  DESCRIPTION"] + names.map { "\($0)  whytap" }).joined(separator: "\n") + "\n"
        }

        let empty = try runBuildFixture(teamID: team, securityOutput: identities,
                                        caseListing: listing(["GITHUB_LENDING_KEY"]), environment: notarize)
        XCTAssertEqual(empty.result.status, 1, empty.result.output)
        XCTAssertTrue(empty.result.output.contains("Missing keys: ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID ASC_API_KEY_P8"),
                      empty.result.output)
        XCTAssertTrue(empty.result.output.contains("Whytap Case project whytap"), empty.result.output)
        XCTAssertEqual(empty.calls, "identity-lookup\nnotary-tools\ncase-ls\n")

        let partial = try runBuildFixture(teamID: team, securityOutput: identities,
            caseListing: listing(["ASC_API_KEY_ID", "ASC_API_KEY_P8_OLD", "ASC_API_KEY_P8"]), environment: notarize)
        XCTAssertEqual(partial.result.status, 1, partial.result.output)
        XCTAssertTrue(partial.result.output.contains("Missing keys: ASC_API_KEY_ISSUER_ID\n"), partial.result.output)
        XCTAssertNil(partial.calls?.range(of: "compiler"), partial.result.output)

        let noHelper = try runBuildFixture(teamID: team, securityOutput: identities, environment: notarize)
        XCTAssertEqual(noHelper.result.status, 1, noHelper.result.output)
        XCTAssertTrue(noHelper.result.output.contains("its command is missing"), noHelper.result.output)
        XCTAssertEqual(noHelper.calls, "identity-lookup\nnotary-tools\n")

        let locked = try runBuildFixture(teamID: team, securityOutput: identities, caseListing: "",
                                         caseStatus: 4, environment: notarize)
        XCTAssertEqual(locked.result.status, 1, locked.result.output)
        XCTAssertTrue(locked.result.output.contains("could not list project whytap (exit 4)"), locked.result.output)
        XCTAssertNil(locked.calls?.range(of: "compiler"), locked.result.output)

        let ready = try runBuildFixture(teamID: team, securityOutput: identities,
            caseListing: listing(["ASC_API_KEY_ID", "ASC_API_KEY_ISSUER_ID", "ASC_API_KEY_P8"]), environment: notarize)
        XCTAssertEqual(ready.result.status, 64, ready.result.output)
        XCTAssertEqual(ready.calls, "identity-lookup\nnotary-tools\ncase-ls\ncompiler\n")
        XCTAssertTrue(ready.result.output.contains("Notarization key found in Whytap Case project whytap"),
                      ready.result.output)

        // Without notarization neither Apple's notary tools nor Case are used.
        let plain = try runBuildFixture(teamID: team, securityOutput: identities, caseListing: listing([]))
        XCTAssertEqual(plain.calls, "identity-lookup\ncompiler\n")
    }

    /// The .p8 reaches notarytool only as a private file that is gone afterwards,
    /// in whichever form a single-line Case field kept it; nothing prints it.
    func test_notarySubmissionKeepsTheKeyPrivateAndRemovesIt() throws {
        let key = try makeNotaryKey()
        let pem = try String(contentsOf: key, encoding: .utf8)
        let base64File = Data(pem.utf8).base64EncodedString()
        for stored in [pem, pem.replacingOccurrences(of: "\n", with: " "),
                       pem.replacingOccurrences(of: "\n", with: ""),
                       pem.replacingOccurrences(of: "\n", with: "\\n"), base64File] {
            let run = try runNotarySubmission(status: "Accepted", p8: stored)
            XCTAssertEqual(run.result.status, 0, run.result.output)
            XCTAssertTrue(run.result.output.contains("Apple accepted Whytap.zip (submission \(Self.submissionID))"),
                          run.result.output)
            XCTAssertEqual(run.keyMode, "600")
            XCTAssertEqual(run.keyCopy, pem)
            XCTAssertEqual(run.leftovers, [], "the private key file must be removed")
            XCTAssertTrue(run.calls.hasPrefix("notarytool submit "), run.calls)
            XCTAssertTrue(run.calls.contains("--wait --timeout 1200 --output-format json"), run.calls)
            XCTAssertFalse(run.calls.contains("BEGIN PRIVATE KEY"), "the key must never be an argument")
            for secret in [Self.keyID, Self.issuerID] + pem.split(separator: "\n").map(String.init) {
                XCTAssertFalse(run.result.output.contains(secret), "output contains key material: \(run.result.output)")
            }
        }

        // Tracing, requested or inherited through SHELLOPTS, never prints the key.
        for (options, extra) in [(["-x"], [String: String]()), ([], ["SHELLOPTS": "xtrace"])] {
            let traced = try runNotarySubmission(status: "Accepted", p8: pem, bashOptions: options,
                                                 environment: extra)
            XCTAssertEqual(traced.result.status, 0, traced.result.output)
            for line in pem.split(separator: "\n") where !line.hasPrefix("-----") {
                XCTAssertFalse(traced.result.output.contains(line), "trace printed the key: \(traced.result.output)")
            }
        }
    }

    /// Bash defers traps while a foreground child runs; a stalled notarytool
    /// must not keep the key on disk after the build is stopped.
    func test_notarySubmissionRemovesTheKeyWhenStoppedDuringTheWait() throws {
        let pem = try String(contentsOf: try makeNotaryKey(), encoding: .utf8)
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for directory in ["bin", "logs", "tmp"] {
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
        let archive = temporary.appendingPathComponent("Whytap.zip")
        try Data("archive".utf8).write(to: archive)
        let waiting = temporary.appendingPathComponent("waiting")
        try executable(at: temporary.appendingPathComponent("bin/xcrun"), contents: """
        #!/bin/bash
        touch '\(waiting.path)'
        exec /bin/sleep 30
        """)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [try projectRoot().appendingPathComponent("scripts/notarize-submit.sh").path,
                             archive.path, temporary.appendingPathComponent("logs").path]
        process.environment = ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                               "TMPDIR": temporary.appendingPathComponent("tmp").path,
                               "ASC_API_KEY_ID": Self.keyID, "ASC_API_KEY_ISSUER_ID": Self.issuerID,
                               "ASC_API_KEY_P8": pem]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: waiting.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: waiting.path), "notarytool stub never started")
        let tmp = temporary.appendingPathComponent("tmp").path
        XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: tmp).isEmpty, "the key file exists while waiting")
        // SIGTERM to the script alone, as a stopped build delivers it.
        let stopped = Date()
        XCTAssertEqual(kill(process.processIdentifier, SIGTERM), 0)
        process.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 10, "SIGTERM waited for notarytool")
        XCTAssertEqual(process.terminationStatus, 143)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: tmp), [])
    }

    func test_notarySubmissionKeepsTheLogOfARejectedArchive() throws {
        let pem = try String(contentsOf: try makeNotaryKey(), encoding: .utf8)
        let rejected = try runNotarySubmission(status: "Invalid", p8: pem)
        XCTAssertEqual(rejected.result.status, 1, rejected.result.output)
        XCTAssertTrue(rejected.result.output.contains("status Invalid"), rejected.result.output)
        XCTAssertTrue(rejected.result.output.contains("error: The signature does not include a secure timestamp."),
                      rejected.result.output)
        XCTAssertEqual(rejected.logs, ["notarization-\(Self.submissionID).json"])
        XCTAssertTrue(rejected.calls.contains("notarytool log \(Self.submissionID) "), rejected.calls)
        XCTAssertEqual(rejected.leftovers, [])

        // A timeout or network failure before Apple recorded a submission.
        let unsubmitted = try runNotarySubmission(status: nil, p8: pem, submitStatus: 1)
        XCTAssertEqual(unsubmitted.result.status, 1, unsubmitted.result.output)
        XCTAssertTrue(unsubmitted.result.output.contains("No submission was recorded"), unsubmitted.result.output)
        XCTAssertEqual(unsubmitted.logs, [])
        XCTAssertEqual(unsubmitted.leftovers, [])

        let unreadable = try runNotarySubmission(status: nil, p8: pem, answer: "Error: not JSON")
        XCTAssertEqual(unreadable.result.status, 1, unreadable.result.output)
        XCTAssertTrue(unreadable.result.output.contains("status unknown"), unreadable.result.output)
        XCTAssertTrue(unreadable.result.output.contains("No submission was recorded"), unreadable.result.output)

        // The wait timed out while Apple was still processing.
        let processing = try runNotarySubmission(status: "In Progress", p8: pem, submitStatus: 1)
        XCTAssertEqual(processing.result.status, 1, processing.result.output)
        XCTAssertTrue(processing.result.output.contains("still processing on Apple's side"), processing.result.output)
        XCTAssertFalse(processing.calls.contains("notarytool log"), processing.calls)

        // Both the verdict and notarytool's exit status must say accepted.
        let contradictory = try runNotarySubmission(status: "Accepted", p8: pem, submitStatus: 1)
        XCTAssertEqual(contradictory.result.status, 1, contradictory.result.output)
        XCTAssertEqual(contradictory.leftovers, [])

        let noLog = try runNotarySubmission(status: "Invalid", p8: pem, logStatus: 1)
        XCTAssertEqual(noLog.result.status, 1, noLog.result.output)
        XCTAssertTrue(noLog.result.output.contains("Could not download the log of submission \(Self.submissionID)"),
                      noLog.result.output)
        XCTAssertEqual(noLog.leftovers, [])
    }

    func test_notarySubmissionNamesMissingOrMalformedKeys() throws {
        let pem = try String(contentsOf: try makeNotaryKey(), encoding: .utf8)
        let missing = try runNotarySubmission(status: "Accepted", p8: pem, omit: ["ASC_API_KEY_ISSUER_ID"])
        XCTAssertEqual(missing.result.status, 1, missing.result.output)
        XCTAssertTrue(missing.result.output.contains("needs ASC_API_KEY_ISSUER_ID in its environment"),
                      missing.result.output)
        XCTAssertEqual(missing.calls, "")

        let malformed = try runNotarySubmission(status: "Accepted", p8: "not a key")
        XCTAssertEqual(malformed.result.status, 1, malformed.result.output)
        XCTAssertTrue(malformed.result.output.contains("ASC_API_KEY_P8 must hold the contents of the AuthKey_<key ID>.p8 file"),
                      malformed.result.output)
        XCTAssertEqual(malformed.calls, "")
        XCTAssertEqual(malformed.leftovers, [])
    }

    /// The upload checks the archive itself, not only the manifest's claim,
    /// before any GitHub call or key access.
    func test_publicationChecksTheStapledTicketOfANotarizedArchive() throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for directory in ["scripts", "Resources", "build", "bin"] {
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
        let root = try projectRoot()
        for relative in ["scripts/upload-release.sh", "Resources/Info.plist.template"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(relative),
                to: temporary.appendingPathComponent(relative))
        }
        try "TEAMID1234\n".write(to: temporary.appendingPathComponent("Resources/developer-id-team.txt"),
                                 atomically: true, encoding: .utf8)
        try Data("test".utf8).write(to: temporary.appendingPathComponent("build/Whytap-9.9.9-build42.dmg"))
        let github = temporary.appendingPathComponent("github-calls.txt")
        try executable(at: temporary.appendingPathComponent("bin/gh"), contents: #"""
        #!/bin/bash
        echo "$1 $2" >> "$PROBE_GITHUB"
        if [ "$1 $2" = "auth status" ] || [ "$1 $2" = "release view" ]; then exit 0; fi
        exit 74
        """#)
        try executable(at: temporary.appendingPathComponent("bin/xcrun"), contents: #"""
        #!/bin/bash
        [ "$1 $2" = "stapler validate" ] || exit 71
        exit "$PROBE_STAPLER_STATUS"
        """#)
        try executable(at: temporary.appendingPathComponent("bin/spctl"), contents: #"""
        #!/bin/bash
        [ "$*" = "--assess -vv --type open --context context:primary-signature $7" ] || exit 71
        printf '%s: accepted\nsource=%s\n' "$7" "$PROBE_SOURCE"
        exit "${PROBE_SPCTL_STATUS:-0}"
        """#)
        try prepareProvenanceFixture(temporary)
        try sealFixture(temporary, archiveName: "Whytap-9.9.9-build42.dmg", codeSigning: "team:TEAMID1234",
                        notarization: "notarized")
        func upload(stapler: String, source: String, spctl: String = "0") throws -> (status: Int32, output: String) {
            try? FileManager.default.removeItem(at: github)
            return try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
                environment: ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                              "FLAVOR": "prod", "APP_BUNDLE_NAME": "Whytap", "SHORT_VERSION": "9.9.9",
                              "BUILD_VERSION": "42", "PROBE_GITHUB": github.path,
                              "PROBE_STAPLER_STATUS": stapler, "PROBE_SOURCE": source,
                              "PROBE_SPCTL_STATUS": spctl])
        }

        let unstapled = try upload(stapler: "65", source: "Notarized Developer ID")
        XCTAssertNotEqual(unstapled.status, 0)
        XCTAssertTrue(unstapled.output.contains("no valid stapled notarization ticket; refusing publication"),
                      unstapled.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: github.path), unstapled.output)

        let unnotarized = try upload(stapler: "0", source: "Unnotarized Developer ID")
        XCTAssertNotEqual(unnotarized.status, 0)
        XCTAssertTrue(unnotarized.output.contains("does not accept Whytap-9.9.9-build42.dmg as notarized"),
                      unnotarized.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: github.path), unnotarized.output)

        let rejected = try upload(stapler: "0", source: "Notarized Developer ID", spctl: "3")
        XCTAssertNotEqual(rejected.status, 0)
        XCTAssertTrue(rejected.output.contains("does not accept Whytap-9.9.9-build42.dmg as notarized"), rejected.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: github.path), rejected.output)

        let notarized = try upload(stapler: "0", source: "Notarized Developer ID")
        XCTAssertNotEqual(notarized.status, 0)
        XCTAssertTrue(notarized.output.contains("stapled ticket and Gatekeeper assessment verified"), notarized.output)
        XCTAssertTrue(notarized.output.contains("already exists; refusing to overwrite"), notarized.output)
        XCTAssertEqual(try String(contentsOf: github, encoding: .utf8), "auth status\nrelease view\n")

        // The opt-out does not accept a notarized archive's manifest either.
        let mismatched = try runScript(temporary.appendingPathComponent("scripts/upload-release.sh"),
            environment: ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                          "FLAVOR": "prod", "APP_BUNDLE_NAME": "Whytap", "SHORT_VERSION": "9.9.9",
                          "BUILD_VERSION": "42", "PROBE_GITHUB": github.path, "EXODIA_NOTARIZE": "0"])
        XCTAssertNotEqual(mismatched.status, 0)
        XCTAssertTrue(mismatched.output.contains("archive notarization (notarized) does not match"), mismatched.output)
    }

    func test_provenanceRecordsNotarizationOnlyForDeveloperID() throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("build"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("scripts"),
                                                withIntermediateDirectories: true)
        try Data("test".utf8).write(to: temporary.appendingPathComponent("build/Whytap-9.9.9-build42.dmg"))
        try prepareProvenanceFixture(temporary)
        let archive = "Whytap-9.9.9-build42.dmg"
        let identity = String(repeating: "a", count: 40)
        try sealFixture(temporary, archiveName: archive, codeSigning: "adhoc", notarization: "notarized",
                        expectSuccess: false, failure: "only Developer ID builds")
        try sealFixture(temporary, archiveName: archive, codeSigning: "certificate:" + identity,
                        notarization: "notarized", expectSuccess: false, failure: "only Developer ID builds")
        try sealFixture(temporary, archiveName: archive, codeSigning: "developer-id", distribution: "developer-id",
                        expectSuccess: false, failure: "always notarized")
        try sealFixture(temporary, archiveName: archive, codeSigning: "team:TEAMID1234", notarization: "notarized")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            temporary.appendingPathComponent("build/\(archive).manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["schema_version"] as? Int, 3)
        XCTAssertEqual(manifest["code_signing"] as? String, "team:TEAMID1234")
        XCTAssertEqual(manifest["notarization"] as? String, "notarized")

        // Existing local builder verifiers omit the new flag. They accept a
        // schema-3 local archive, but cannot reinterpret a notarized manifest.
        let helper = temporary.appendingPathComponent("scripts/release-provenance.py")
        let environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let arguments = [helper.path, "verify", "--project-root", temporary.path,
            "--archive", temporary.appendingPathComponent("build/" + archive).path,
            "--version", "9.9.9", "--build", "42", "--flavor", "prod",
            "--distribution", "community", "--code-signing", "team:TEAMID1234"]
        let implicitNotarized = try runTool(URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: arguments, environment: environment)
        XCTAssertNotEqual(implicitNotarized.status, 0)
        XCTAssertTrue(implicitNotarized.output.contains("archive notarization (notarized) does not match"),
                      implicitNotarized.output)
        try sealFixture(temporary, archiveName: archive, codeSigning: "team:TEAMID1234")
        let local = try runTool(URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: arguments, environment: environment)
        XCTAssertEqual(local.status, 0, local.output)
        let publication = try runTool(URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: arguments + ["--notarization", "notarized"], environment: environment)
        XCTAssertNotEqual(publication.status, 0)
        XCTAssertTrue(publication.output.contains("archive notarization (none) does not match"), publication.output)
    }

    private static let keyID = "ABCDE12345"
    private static let issuerID = "69a6de70-0000-47e3-e053-5b8c7c11a4d1"
    private static let submissionID = "11111111-2222-3333-4444-555555555555"

    /// A throwaway PKCS#8 P-256 key in the format of an App Store Connect .p8 file.
    private func makeNotaryKey() throws -> URL {
        let directory = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("AuthKey_\(Self.keyID).p8")
        let created = try runTool(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
            "/usr/bin/openssl ecparam -name prime256v1 -genkey -noout | /usr/bin/openssl pkcs8 -topk8 -nocrypt -out \"$1\"",
            "sh", key.path], environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(created.status, 0, created.output)
        return key
    }

    /// Runs notarize-submit.sh against a notarytool stub answering `status`
    /// (nil: no answer) and reports what the stub saw and what stayed behind.
    private func runNotarySubmission(status: String?, p8: String, submitStatus: Int32 = 0,
                                     answer: String? = nil, logStatus: Int32 = 0,
                                     omit: Set<String> = [], bashOptions: [String] = [],
                                     environment extra: [String: String] = [:]) throws
        -> (result: (status: Int32, output: String), calls: String, keyMode: String?, keyCopy: String?,
            logs: [String], leftovers: [String]) {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        for directory in ["bin", "logs", "tmp"] {
            try FileManager.default.createDirectory(at: temporary.appendingPathComponent(directory),
                withIntermediateDirectories: true)
        }
        let archive = temporary.appendingPathComponent("Whytap.zip")
        try Data("archive".utf8).write(to: archive)
        let answer = answer
            ?? status.map { #"{"id":"\#(Self.submissionID)","status":"\#($0)","message":"Processing complete"}"# } ?? ""
        try executable(at: temporary.appendingPathComponent("bin/xcrun"), contents: """
        #!/bin/bash
        echo "$*" >> "$PROBE_DIR/calls"
        if [ "$1 $2" = "notarytool submit" ]; then
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--key" ]; then key="$2"; fi
                shift
            done
            stat -f %Lp "$key" > "$PROBE_DIR/key-mode"
            cp "$key" "$PROBE_DIR/key-copy"
            echo '\(answer)'
            exit \(submitStatus)
        fi
        if [ "$1 $2" = "notarytool log" ]; then
            for last; do :; done
            echo '{"issues":[{"severity":"error","path":"Whytap.zip/Whytap.app","message":"The signature does not include a secure timestamp."}]}' > "$last"
            exit \(logStatus)
        fi
        exit 71
        """)
        var environment = ["PATH": temporary.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                           "TMPDIR": temporary.appendingPathComponent("tmp").path, "PROBE_DIR": temporary.path,
                           "ASC_API_KEY_ID": Self.keyID, "ASC_API_KEY_ISSUER_ID": Self.issuerID,
                           "ASC_API_KEY_P8": p8]
        environment.merge(extra) { $1 }
        for name in omit { environment.removeValue(forKey: name) }
        let result = try runTool(URL(fileURLWithPath: "/bin/bash"), arguments: bashOptions + [
            try projectRoot().appendingPathComponent("scripts/notarize-submit.sh").path,
            archive.path, temporary.appendingPathComponent("logs").path], environment: environment)
        func read(_ name: String) -> String? {
            try? String(contentsOf: temporary.appendingPathComponent(name), encoding: .utf8)
        }
        let files = { (name: String) in
            ((try? FileManager.default.subpathsOfDirectory(atPath: temporary.appendingPathComponent(name).path)) ?? []).sorted()
        }
        return (result, read("calls") ?? "", read("key-mode")?.trimmingCharacters(in: .whitespacesAndNewlines),
                read("key-copy"), files("logs"), files("tmp"))
    }

    func test_scriptRunnerDrainsOutputLargerThanPipeCapacity() throws {
        let result = try runTool(URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; sys.stdout.write('x' * 262144)"],
            environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 262144)
    }

    private func runScript(_ script: URL, arguments: [String] = [],
                           environment: [String: String]) throws -> (status: Int32, output: String) {
        try runTool(URL(fileURLWithPath: "/bin/bash"), arguments: [script.path] + arguments,
                    environment: environment)
    }

    private func runTool(_ executable: URL, arguments: [String],
                         environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain while the child runs: waiting first can fill the pipe and
        // deadlock even an otherwise successful packaging command.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: data, as: UTF8.self))
    }

    /// Runs build-dmg.sh in a minimal committed checkout whose compiler stub exits 64.
    /// `calls` lists the stubbed compiler and Apple tools that ran, nil when none did.
    /// With `securityOutput` the `security` stub prints it as the identity listing.
    /// With `caseListing` a Case helper stub prints it for `case ls -p whytap`
    /// and exits with `caseStatus`; without it the helper is missing. The real
    /// Case is never used.
    private func runBuildFixture(certificate: URL? = nil, teamID: String? = nil,
                                 securityOutput: String? = nil, caseListing: String? = nil,
                                 caseStatus: Int32 = 0, arguments: [String] = [],
                                 environment: [String: String] = [:]) throws
        -> (result: (status: Int32, output: String), calls: String?) {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let tools = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let marker = temporary.appendingPathComponent("calls.txt")
        let root = try projectRoot()
        for relative in ["scripts/build-dmg.sh", "scripts/dmg-layout.py", "scripts/_vendor",
                         "VERSION", "Package.resolved", "Resources/dmg-background.png",
                         "Resources/Info.plist.template", "Resources/sparkle-public-ed-key.txt",
                         "Resources/blocknote/index.html"] {
            let destination = temporary.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent(relative), to: destination)
        }
        if let certificate {
            try FileManager.default.copyItem(at: certificate,
                to: temporary.appendingPathComponent("Resources/community-signing-certificate.pem"))
        }
        if let teamID {
            try (teamID + "\n").write(to: temporary.appendingPathComponent("Resources/developer-id-team.txt"),
                                      atomically: true, encoding: .utf8)
        }
        try executable(at: tools.appendingPathComponent("swift"), contents: #"""
        #!/bin/bash
        echo compiler >> "$PROBE_MARKER"
        exit 64
        """#)
        if let securityOutput {
            let listing = temporary.appendingPathComponent("identities.txt")
            try securityOutput.write(to: listing, atomically: true, encoding: .utf8)
            try executable(at: tools.appendingPathComponent("security"), contents: """
            #!/bin/bash
            if [ "$*" != "find-identity -v -p codesigning" ]; then
                echo unexpected-apple >> "$PROBE_MARKER"
                exit 71
            fi
            echo identity-lookup >> "$PROBE_MARKER"
            cat '\(listing.path)'
            """)
        } else {
            try executable(at: tools.appendingPathComponent("security"), contents: #"""
            #!/bin/bash
            echo unexpected-apple >> "$PROBE_MARKER"
            exit 71
            """#)
        }
        try executable(at: tools.appendingPathComponent("xcrun"), contents: #"""
        #!/bin/bash
        if [ "$*" = "--sdk macosx --show-sdk-version" ]; then
            echo 26.4
            exit 0
        fi
        if [ "$*" = "notarytool --version" ]; then
            echo notary-tools >> "$PROBE_MARKER"
            echo 1.1.1
            exit 0
        fi
        echo unexpected-apple >> "$PROBE_MARKER"
        exit 71
        """#)
        let caseHelper = temporary.appendingPathComponent("case-helper/whytap")
        if let caseListing {
            try FileManager.default.createDirectory(at: caseHelper.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let listing = temporary.appendingPathComponent("case-listing.txt")
            try caseListing.write(to: listing, atomically: true, encoding: .utf8)
            try executable(at: caseHelper, contents: """
            #!/bin/bash
            if [ "$*" != "case ls -p whytap" ]; then
                echo unexpected-case >> "$PROBE_MARKER"
                exit 70
            fi
            echo case-ls >> "$PROBE_MARKER"
            cat '\(listing.path)'
            exit \(caseStatus)
            """)
        }
        try prepareProvenanceFixture(temporary)
        let result = try runScript(temporary.appendingPathComponent("scripts/build-dmg.sh"),
            arguments: arguments,
            environment: ["PATH": tools.path + ":/usr/bin:/bin", "PROBE_MARKER": marker.path,
                          "BUILD_VERSION": "42", "FLAVOR": "prod",
                          "EXODIA_CASE_HELPER": caseHelper.path].merging(environment) { $1 })
        return (result, try? String(contentsOf: marker, encoding: .utf8))
    }

    /// A throwaway self-signed code-signing identity like the community one.
    private func makeSigningIdentity(in directory: URL, name: String) throws
        -> (certificate: URL, key: URL, sha1: String) {
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        let key = directory.appendingPathComponent(name + "-key.pem")
        let certificate = directory.appendingPathComponent(name + "-certificate.pem")
        let created = try runTool(openssl, arguments: ["req", "-x509", "-newkey", "rsa:2048", "-sha256",
            "-days", "2", "-nodes", "-keyout", key.path, "-out", certificate.path,
            "-subj", "/CN=Whytap Test Signing " + name,
            "-addext", "basicConstraints=critical,CA:false",
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=critical,codeSigning"], environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(created.status, 0, created.output)
        let fingerprint = try runTool(openssl, arguments: ["x509", "-in", certificate.path, "-noout",
            "-fingerprint", "-sha1"], environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(fingerprint.status, 0, fingerprint.output)
        let sha1 = String(fingerprint.output.split(separator: "=").last ?? "")
            .replacingOccurrences(of: ":", with: "").lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(sha1.count, 40, fingerprint.output)
        return (certificate, key, sha1)
    }

    private func prepareProvenanceFixture(_ directory: URL, archiveName: String? = nil) throws {
        let helper = directory.appendingPathComponent("scripts/release-provenance.py")
        try FileManager.default.copyItem(at: try projectRoot().appendingPathComponent("scripts/release-provenance.py"),
            to: helper)
        try "build/\n.build/\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        for arguments in [["init", "-q"], ["config", "user.name", "Release Fixture"],
                          ["config", "user.email", "fixture@example.invalid"],
                          ["config", "commit.gpgsign", "false"], ["config", "core.hooksPath", "/dev/null"],
                          ["config", "core.fsmonitor", "false"], ["add", "."], ["commit", "-qm", "fixture"]] {
            let result = try runTool(URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", directory.path] + arguments, environment: environment)
            XCTAssertEqual(result.status, 0, result.output)
        }
        if let archiveName {
            try sealFixture(directory, archiveName: archiveName, codeSigning: "adhoc")
        }
    }

    @discardableResult
    private func sealFixture(_ directory: URL, archiveName: String, codeSigning: String,
                             notarization: String = "none", distribution: String = "community",
                             expectSuccess: Bool = true,
                             failure: String = "code signing must be") throws -> Int32 {
        let helper = directory.appendingPathComponent("scripts/release-provenance.py")
        let environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let captured = try runTool(URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [helper.path, "capture", "--project-root", directory.path], environment: environment)
        XCTAssertEqual(captured.status, 0, captured.output)
        let result = try runTool(URL(fileURLWithPath: "/usr/bin/python3"), arguments: [helper.path, "seal",
            "--project-root", directory.path, "--source-sha", captured.output.trimmingCharacters(in: .whitespacesAndNewlines),
            "--archive", directory.appendingPathComponent("build/" + archiveName).path,
            "--version", "9.9.9", "--build", "42", "--flavor", "prod", "--distribution", distribution,
            "--code-signing", codeSigning, "--notarization", notarization],
            environment: environment)
        if expectSuccess {
            XCTAssertEqual(result.status, 0, result.output)
        } else {
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains(failure), result.output)
        }
        return result.status
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExodiaPackagingTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func executable(at path: URL, contents: String) throws {
        try (contents + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
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
