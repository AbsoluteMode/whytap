import XCTest
@testable import Sidekey

/// Settings -> Other -> Agent replaced the Agents tab.
@MainActor
final class AgentOtherSectionTests: XCTestCase {
    func test_switch_is_on_only_when_enabled_and_connected() {
        XCTAssertTrue(AgentOtherSection.isOn(enabled: true, activeProvider: .native))
        XCTAssertFalse(AgentOtherSection.isOn(enabled: true, activeProvider: nil))
        XCTAssertFalse(AgentOtherSection.isOn(enabled: false, activeProvider: .native))
        XCTAssertFalse(AgentOtherSection.isOn(enabled: false, activeProvider: nil))
    }

    func test_descriptions_name_no_remappable_key() {
        for text in [AgentOtherSection.subtitle, AgentOtherSection.actionsSubtitle] {
            for key in ["Right Command", "Right Option", "Command", "⌘", "⌥"] {
                XCTAssertFalse(text.contains(key), "\(text) names \(key)")
            }
        }
        XCTAssertEqual(AgentOtherSection.actionsTitle, "Allow file edits and commands")
    }

    func test_video_shortcuts_follow_the_live_agent_keys() {
        var configuration = HotkeyConfiguration.defaults
        configuration.agentTextShortcut = .modifier(.rightOption)
        configuration.agentVoiceShortcut = .combo(.optionPeriod)
        let shortcuts = AgentOtherSection.videoShortcuts(configuration)
        XCTAssertEqual(shortcuts.map(\.label), ["Text", "Voice"])
        XCTAssertEqual(shortcuts[0].contents, [HotkeyModifierKey.rightOption.keycapContent])
        XCTAssertEqual(shortcuts[1].contents, [.text(HotkeyGlyph.option), .text(".")])
    }

    func test_feature_videos_are_bundled_resources_not_downloads() throws {
        let root = try projectRoot()
        for video in FeatureVideo.allCases {
            let file = root.appendingPathComponent("Resources/FeatureVideos/\(video.rawValue).mp4")
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
            XCTAssertGreaterThan(size, 100_000, "\(video) clip missing")
            XCTAssertLessThan(size, 3_000_000, "\(video) clip too large for the app bundle")
        }
        for script in ["scripts/dev-run.sh", "scripts/build-dmg.sh"] {
            let text = try String(contentsOf: root.appendingPathComponent(script), encoding: .utf8)
            XCTAssertTrue(text.contains("Resources/FeatureVideos"), "\(script) must copy the feature videos")
        }
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Sidekey/Settings/FeatureVideo.swift"),
                                encoding: .utf8)
        XCTAssertFalse(source.contains("http"), "feature videos must never be fetched")
    }

    func test_workspace_url_matches_the_folder_the_agent_uses() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentDaemonWorkingDirectory.url(appSupportDirectory: temp).path))
        let ensured = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: temp)
        XCTAssertEqual(AgentDaemonWorkingDirectory.url(appSupportDirectory: temp).standardizedFileURL,
                       ensured.standardizedFileURL)
    }

    func test_no_user_facing_copy_still_sends_people_to_the_agents_tab() throws {
        let root = try projectRoot().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for file in files {
            let s = try String(contentsOf: file, encoding: .utf8)
            for line in s.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for stale in ["Settings → Agents", "Settings -> Agents", "Settings > Agents"] {
                    XCTAssertFalse(line.contains(stale), "\(file.lastPathComponent): \(line)")
                }
            }
        }
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "AgentOtherSectionTests", code: 1)
    }
}
