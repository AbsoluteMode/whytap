import XCTest

@MainActor
final class IslandCaseVaultPanelTests: XCTestCase {
    func test_caseVaultPanelUsesSecureValueEntryAndNeverRendersStoredValues() throws {
        let source = try caseVaultPanelSource()

        XCTAssertTrue(source.contains("SecureField"))
        XCTAssertTrue(source.contains("submitValue"))
        XCTAssertTrue(source.contains("copySecret"))
        XCTAssertTrue(source.contains("copyAll"))
        XCTAssertTrue(source.contains("replaceSecret"))
        XCTAssertTrue(source.contains("deleteSecret"))
        XCTAssertFalse(source.contains("CaseSecretValue"))
        XCTAssertFalse(source.contains(".value(for:"))
    }

    func test_caseVaultPanelSupportsGroupsAndDragAutoScroll() throws {
        let source = try caseVaultPanelSource()

        XCTAssertTrue(source.contains("createGroup"))
        XCTAssertTrue(source.contains("addSecretToGroup"))
        XCTAssertTrue(source.contains("removeSecretFromGroup"))
        XCTAssertTrue(source.contains("childRows(forGroupID:"))
        XCTAssertTrue(source.contains("CaseDragAutoScrollPolicy.velocity"))
        XCTAssertTrue(source.contains("UTType.text"))
    }

    func test_caseVaultPanelAutoUnlocksOnOpenAndKeepsRetryWithoutSettingsRoute() throws {
        let source = try caseVaultPanelSource()

        XCTAssertTrue(source.contains("unlockIfNeededOnOpen()"))
        XCTAssertTrue(source.contains("hasTriggeredInitialUnlock"))
        XCTAssertTrue(source.contains("Retry Unlock"))
        XCTAssertTrue(source.contains("Unlocking..."))
        XCTAssertTrue(source.contains("Touch ID"))
        XCTAssertFalse(source.contains("openSettings"))
        XCTAssertFalse(source.contains("Settings"))
    }

    func test_caseVaultPanelArmedResetWarnsAboutPermanentDeletion() throws {
        let source = try caseVaultPanelSource()

        // Two-step confirm: armed state must flip the button label AND swap the
        // supporting copy to spell out that the second press is irreversible.
        XCTAssertTrue(source.contains("Confirm Reset"))
        XCTAssertTrue(source.contains("This permanently deletes this Case. Press again to confirm."))
    }

    private func caseVaultPanelSource() throws -> String {
        let root = try projectRoot()
        let url = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("DynamicIsland")
            .appendingPathComponent("IslandCaseVaultPanel.swift")
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
        throw NSError(domain: "IslandCaseVaultPanelTests", code: 1)
    }
}
