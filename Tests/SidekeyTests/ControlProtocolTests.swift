import XCTest
@testable import Sidekey

final class ControlProtocolTests: XCTestCase {
    private func obj(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
    }

    func testUserMessageShape() {
        let line = ControlProtocol.userMessage("hello bro")
        let o = obj(line)
        XCTAssertEqual(o["type"] as? String, "user")
        let msg = o["message"] as! [String: Any]
        XCTAssertEqual(msg["role"] as? String, "user")
        XCTAssertEqual(msg["content"] as? String, "hello bro")
    }

    func testAllowEchoesInput() {
        let input = "{\"command\":\"echo hi\",\"description\":\"d\"}"
        let line = ControlProtocol.controlResponse(
            requestId: "rid-1", decision: .allow(inputJSON: input))
        let o = obj(line)
        XCTAssertEqual(o["type"] as? String, "control_response")
        let resp = o["response"] as! [String: Any]
        XCTAssertEqual(resp["subtype"] as? String, "success")
        XCTAssertEqual(resp["request_id"] as? String, "rid-1")
        let inner = resp["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "allow")
        let updated = inner["updatedInput"] as! [String: Any]
        XCTAssertEqual(updated["command"] as? String, "echo hi")
        XCTAssertEqual(updated["description"] as? String, "d")
    }

    func testDenyCarriesMessage() {
        let line = ControlProtocol.controlResponse(
            requestId: "rid-2", decision: .deny(message: "User declined in Whytap"))
        let inner = (obj(line)["response"] as! [String: Any])["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "deny")
        XCTAssertEqual(inner["message"] as? String, "User declined in Whytap")
        XCTAssertNil(inner["updatedInput"])
    }
}
