import XCTest
@testable import Sidekey

final class BYOKRealtimeURLTests: XCTestCase {
    func testOpenAIDefaultHost() {
        let url = BYOKRealtimeURL.openAIRealtime(baseURL: nil)
        XCTAssertEqual(url.absoluteString, "wss://api.openai.com/v1/realtime?intent=transcription")
    }

    func testSelfHostedHttpsBecomesWss() {
        let url = BYOKRealtimeURL.openAIRealtime(baseURL: "https://stt.example.com")
        XCTAssertEqual(url.absoluteString, "wss://stt.example.com/v1/realtime?intent=transcription")
    }

    func testSelfHostedWithTrailingSlashAndPort() {
        let url = BYOKRealtimeURL.openAIRealtime(baseURL: "http://localhost:8000/")
        XCTAssertEqual(url.absoluteString, "wss://localhost:8000/v1/realtime?intent=transcription")
    }
}
