import XCTest
@testable import Sidekey

/// `MeetingsCoordinator.extractH1Title` derives the sidebar title from the
/// note markdown's H1. The structured protocol prefixes the note with an
/// `<!-- protocol:v1 -->` marker line, so the extractor must skip it and still
/// find the H1 below — otherwise new meetings show "Untitled".
@MainActor
final class MeetingTitleExtractionTests: XCTestCase {

    func test_extracts_h1_after_protocol_marker() {
        let md = "<!-- protocol:v1 -->\n# Обсуждение монетизации\n\nОписание."
        XCTAssertEqual(MeetingsCoordinator.extractH1Title(from: md), "Обсуждение монетизации")
    }

    func test_extracts_plain_h1() {
        XCTAssertEqual(MeetingsCoordinator.extractH1Title(from: "# Weekly sync\n\nbody"), "Weekly sync")
    }

    func test_tolerates_leading_blank_lines() {
        XCTAssertEqual(MeetingsCoordinator.extractH1Title(from: "\n\n# Title"), "Title")
    }

    func test_marker_then_blank_then_h1() {
        XCTAssertEqual(MeetingsCoordinator.extractH1Title(from: "<!-- protocol:v1 -->\n\n# T"), "T")
    }

    func test_nil_when_no_h1() {
        XCTAssertNil(MeetingsCoordinator.extractH1Title(from: "no heading here"))
        XCTAssertNil(MeetingsCoordinator.extractH1Title(from: "<!-- protocol:v1 -->\nno heading"))
    }
}
