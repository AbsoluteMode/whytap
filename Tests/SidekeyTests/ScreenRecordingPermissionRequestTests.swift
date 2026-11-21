import XCTest
@testable import Sidekey

@MainActor
final class ScreenRecordingPermissionRequestTests: XCTestCase {
    func testFailedNativeRequestIsNotAnError() async {
        var requests = 0
        await ScreenRecordingPermissionRequest.request(isGranted: { false }, requestContent: {
            requests += 1
            throw NSError(domain: "PermissionTest", code: 1)
        })
        XCTAssertEqual(requests, 1)
    }

    func testAlreadyGrantedDoesNotRequest() async {
        var requests = 0
        await ScreenRecordingPermissionRequest.request(isGranted: { true }, requestContent: { requests += 1 })
        XCTAssertEqual(requests, 0)
    }
}
