import XCTest
@testable import Sidekey

@MainActor
final class GoogleSearchControllerTests: XCTestCase {
    func testSubmitTextOpensGoogleURL() {
        var opened: [URL] = []
        let c = GoogleSearchController(openURL: { opened.append($0) },
                                       voiceSessionFactory: { nil })
        c.submitText("hello world")
        XCTAssertEqual(opened.map(\.absoluteString),
                       ["https://www.google.com/search?q=hello%20world"])
    }

    func testSubmitEmptyTextDoesNotOpen() {
        var opened: [URL] = []
        let c = GoogleSearchController(openURL: { opened.append($0) },
                                       voiceSessionFactory: { nil })
        c.submitText("   ")
        XCTAssertTrue(opened.isEmpty)
    }

    func testTranscriptResultOpensGoogleURL() async {
        var opened: [URL] = []
        let c = GoogleSearchController(openURL: { opened.append($0) },
                                       voiceSessionFactory: { nil })
        await c.handleStreamResultForTesting(.transcript("weather today"))
        XCTAssertEqual(opened.map(\.absoluteString),
                       ["https://www.google.com/search?q=weather%20today"])
    }

    func testCancelledResultDoesNotOpen() async {
        var opened: [URL] = []
        let c = GoogleSearchController(openURL: { opened.append($0) },
                                       voiceSessionFactory: { nil })
        await c.handleStreamResultForTesting(.cancelled)
        XCTAssertTrue(opened.isEmpty)
    }

    func testEndpointDetectedResultOpensGoogleURL() async {
        var opened: [URL] = []
        let c = GoogleSearchController(openURL: { opened.append($0) },
                                       voiceSessionFactory: { nil })
        await c.handleStreamResultForTesting(.endpointDetected("news"))
        XCTAssertEqual(opened.map(\.absoluteString),
                       ["https://www.google.com/search?q=news"])
    }

    func testHoldStartBridgesLivePartialsToOnTranscript() async throws {
        // Regression: the Google voice session never wired onTranscriptUpdate,
        // so the island wing showed no live words. It must bridge partials the
        // same way the agent path does.
        var transcripts: [String] = []
        let session = FakeGoogleVoiceSession(partials: ["weath", "weather to"])
        let c = GoogleSearchController(
            openURL: { _ in },
            voiceSessionFactory: { session },
            onTranscript: { transcripts.append($0) }
        )
        c.handleHoldStart()
        let deadline = Date().addingTimeInterval(2.0)
        while transcripts.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(transcripts, ["weath", "weather to"],
            "Google voice must bridge live partials into the island wing like the agent path")
    }
}

@MainActor
private final class FakeGoogleVoiceSession: StreamingSessionRunning {
    var onTranscriptUpdate: ((String) -> Void)?
    private let partials: [String]
    init(partials: [String]) { self.partials = partials }
    func run() async -> StreamingSessionResult {
        for p in partials { onTranscriptUpdate?(p) }
        return .cancelled
    }
    func stop() async {}
    func cancel() async {}
}
