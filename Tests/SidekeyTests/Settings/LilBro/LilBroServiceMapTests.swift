import Foundation
import XCTest
@testable import Sidekey

/// REV 22: Lil Bro's model reads the whole service from a map built from this
/// revision's code. Every feature has its full block, every row the map names
/// exists, every catalog row is in exactly one block, and the checked-in copy
/// whytap.ai reads is current. A new feature or row without its place here
/// fails. Regenerate with `LILBRO_WRITE_SERVICE_MAP=1 swift test --filter LilBroServiceMapTests`.
// WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md (REV 22)
@MainActor
final class LilBroServiceMapTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    func test_every_feature_has_a_full_block() {
        for feature in AppFeature.allCases {
            let block = LilBroServiceMap.block(feature).joined(separator: "\n")
            let name = feature.rawValue
            for part in ["What it does: ", "How to use: ", "What it needs:", "Settings (row id", "Common problems:"] {
                XCTAssertTrue(block.contains(part), "\(name) has no “\(part)”")
            }
            XCTAssertFalse(FeatureCatalog.info(for: feature).line.isEmpty, name)
            XCTAssertFalse(LilBroRow.catalog.filter { $0.feature == feature }.isEmpty, "\(name) has no settings rows")
            XCTAssertFalse(LilBroServiceMap.problems(feature).isEmpty, "\(name) has no common problems")
        }
    }

    func test_every_row_the_map_names_exists() {
        let ids = Set(LilBroRow.catalog.map(\.id))
        let missing = LilBroServiceMap.troubleRows.filter { !ids.contains($0) }
        XCTAssertEqual(missing, [], "problems name rows that are not in LilBroRow.catalog")
    }

    func test_every_catalog_row_is_in_exactly_one_block() {
        let text = LilBroServiceMap.text
        var lines: [String: Int] = [:]
        for line in text.components(separatedBy: "\n") where line.hasPrefix("- ") {
            let id = line.dropFirst(2).prefix { $0 != ":" }
            lines[String(id), default: 0] += 1
        }
        var notOnce: [String] = []
        for row in LilBroRow.catalog where lines[row.id] != 1 {
            notOnce.append("\(row.id) ×\(lines[row.id] ?? 0)")
        }
        XCTAssertEqual(notOnce, [], "each row is listed once, under its feature or its screen")
    }

    func test_the_checked_in_map_is_current() throws {
        let url = Self.root.appendingPathComponent(LilBroServiceMap.path)
        let text = LilBroServiceMap.text
        if ProcessInfo.processInfo.environment["LILBRO_WRITE_SERVICE_MAP"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(saved, text, "regenerate \(LilBroServiceMap.path) (LILBRO_WRITE_SERVICE_MAP=1)")
    }

    /// It rides on every question as the cached prefix: small enough to be
    /// cheap, and with no key value, address or anything of this Mac.
    func test_the_map_is_compact_and_holds_nothing_of_this_mac() {
        let text = LilBroServiceMap.text
        XCTAssertLessThan(text.utf8.count, 60_000)
        for word in ["/Users/", "sk-", "http://", "@"] {
            XCTAssertFalse(text.contains(word), word)
        }
    }
}
