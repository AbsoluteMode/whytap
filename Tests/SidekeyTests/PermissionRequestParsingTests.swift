import XCTest
@testable import Sidekey

final class PermissionRequestParsingTests: XCTestCase {
    func testParsesCanUseTool() {
        let line = #"{"type":"control_request","request_id":"e60b5771","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"curl -fsS https://example.com","description":"Check status"},"description":"Check status","tool_use_id":"toolu_01"}}"#
        let events = StreamJSONParser.parse(line: line)
        guard case .permissionRequest(let rid, let tool, let summary, let inputJSON)? =
                events.first else {
            return XCTFail("expected permissionRequest")
        }
        XCTAssertEqual(rid, "e60b5771")
        XCTAssertEqual(tool, "Bash")
        XCTAssertEqual(summary, "Check status")
        let input = try! JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as! [String: Any]
        XCTAssertEqual(input["command"] as? String, "curl -fsS https://example.com")
    }

    func testNonCanUseToolControlRequestIgnored() {
        let line = #"{"type":"control_request","request_id":"x","request":{"subtype":"initialize"}}"#
        XCTAssertEqual(StreamJSONParser.parse(line: line), [])
    }

    func testMapperEmitsPermissionRequest() {
        let ev = ClaudeStreamEvent.permissionRequest(
            requestId: "r1", toolName: "Bash", summary: "run curl", inputJSON: "{\"command\":\"curl\"}")
        XCTAssertEqual(
            ClaudeEventMapper.map(ev),
            [.permissionRequest(id: "r1", toolName: "Bash", summary: "run curl", inputJSON: "{\"command\":\"curl\"}")])
    }
}
