import XCTest
@testable import Sidekey

@MainActor
final class AgentRealtimeVoiceSessionTests: XCTestCase {
    func testProductionSessionsConformToProtocol() {
        // Compile-time proof the production sessions satisfy the protocol
        // the controller depends on.
        let _: any AgentRealtimeVoiceSessioning.Type = DirectProviderStreamingSession.self
        let _: any AgentRealtimeVoiceSessioning.Type = LocalTranscriptionSession.self
    }
}
