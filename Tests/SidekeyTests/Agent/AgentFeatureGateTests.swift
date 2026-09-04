import XCTest
@testable import Sidekey

final class AgentFeatureGateTests: XCTestCase {
    func testEnabledMappingByFlavor() {
        XCTAssertTrue(AgentFeatureGate.isEnabled(for: .dev))
        XCTAssertTrue(AgentFeatureGate.isEnabled(for: .beta))
        XCTAssertTrue(AgentFeatureGate.isEnabled(for: .prod))
    }

    func testTextModeFollowsMainGate() {
        XCTAssertTrue(AgentFeatureGate.isTextEnabled(for: .dev))
        XCTAssertTrue(AgentFeatureGate.isTextEnabled(for: .beta))
        XCTAssertTrue(AgentFeatureGate.isTextEnabled(for: .prod))
    }

    func testVoiceModeFollowsGateAndProviderReadiness() {
        XCTAssertTrue(AgentFeatureGate.isVoiceEnabled(for: .beta, providerReady: true))
        XCTAssertFalse(AgentFeatureGate.isVoiceEnabled(for: .beta, providerReady: false))
        XCTAssertTrue(AgentFeatureGate.isVoiceEnabled(for: .prod, providerReady: true))
        XCTAssertFalse(AgentFeatureGate.isVoiceEnabled(for: .prod, providerReady: false))
    }

    func testCurrentBuildMapping() {
        XCTAssertTrue(AgentFeatureGate.isEnabled)
        XCTAssertTrue(AgentFeatureGate.isTextEnabled)
        XCTAssertTrue(AgentFeatureGate.isVoiceEnabled)
    }

    func testResilientDropDeliveryFlavorGate() {
        // Promoted to prod 2026-06-20: ON on every flavor. The off-path is
        // bit-for-bit old behavior and a false-positive degrade still delivers
        // the text (batch recovery), so the bounded downside justified shipping
        // straight to prod after the beta build.
        XCTAssertTrue(AgentFeatureGate.resilientDropDeliveryEnabled(for: .dev))
        XCTAssertTrue(AgentFeatureGate.resilientDropDeliveryEnabled(for: .beta))
        XCTAssertTrue(AgentFeatureGate.resilientDropDeliveryEnabled(for: .prod))
    }

}
