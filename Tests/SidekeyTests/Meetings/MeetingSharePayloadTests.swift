import XCTest
@testable import Sidekey

final class MeetingSharePayloadTests: XCTestCase {
    func test_payload_derives_markdown_attachment_name_from_first_heading() throws {
        let payload = try XCTUnwrap(MeetingSharePayload(markdown: """
        # Roadmap / Q3: Kickoff?

        - Align scope
        """))

        XCTAssertEqual(payload.attachmentFileName, "Roadmap Q3 Kickoff.md")
    }

    func test_payload_uses_fallback_attachment_name_without_heading() throws {
        let payload = try XCTUnwrap(MeetingSharePayload(markdown: "- one\n- two"))

        XCTAssertEqual(payload.attachmentFileName, "Meeting notes.md")
    }

    func test_attachment_writer_creates_utf8_markdown_file() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = try XCTUnwrap(MeetingSharePayload(markdown: "# Weekly sync\n\nDone."))

        let url = try MeetingShareAttachmentWriter.writeMarkdownAttachment(
            for: payload,
            in: directory
        )

        XCTAssertEqual(url.lastPathComponent, "Weekly sync.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Weekly sync\n\nDone.")
    }
}
