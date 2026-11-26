import Foundation
import XCTest
@testable import Sidekey

/// REV 17: Lil Bro is told what is wrong on this Mac, and only that.
@MainActor
final class LilBroStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private var healthy: FeatureSetupSnapshot {
        var snapshot = FeatureSetupSnapshot()
        snapshot.dropMode = .fast
        snapshot.models = [.dropFast: .ok]
        snapshot.microphoneGranted = true
        snapshot.keyboardReady = true
        snapshot.screenRecordingGranted = true
        return snapshot
    }

    func test_a_mac_where_everything_works_sends_nothing() throws {
        let status = LilBroStatus.make(snapshot: healthy, keyChecks: [.soniox: .valid], failures: [], now: now)
        XCTAssertTrue(status.isEmpty)
        let request = try LilBroRemoteBrain.request(for: LilBroQuestion(text: "почему не работает", status: status))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["status"], "no status field when all is well: no tokens spent on it")
    }

    func test_what_is_wrong_is_named_by_state_only() throws {
        var snapshot = healthy
        snapshot.microphoneGranted = false
        snapshot.keyboardNeedsRestart = true
        snapshot.screenRecordingGranted = false
        snapshot.meetingsOn = true
        snapshot.models = [.dropFast: .keyProblem, .meetings: .notSet, .meetingNotes: .ok, .agent: .notSet]
        let failures = [
            LilBroFailureLog.Entry(provider: .soniox, feature: .dropFast, failure: .outOfCredit, at: now.addingTimeInterval(-180)),
            LilBroFailureLog.Entry(provider: .openAI, feature: .dropFast, failure: .busy, at: now.addingTimeInterval(-90_000)),
        ]
        let status = LilBroStatus.make(snapshot: snapshot,
                                       keyChecks: [.soniox: .rejected(.outOfCredit), .openAI: .valid, .anthropic: .unreachable],
                                       failures: failures, now: now)
        XCTAssertEqual(status.permissions, ["microphone": "missing", "accessibility": "needsRestart",
                                            "screenRecording": "missing", "systemAudio": "unknown"])
        XCTAssertEqual(status.keys, ["soniox": "outOfCredit", "anthropic": "unreachable"], "a working key is not listed")
        XCTAssertEqual(status.routes, ["dropFast": "keyProblem", "meetings": "notSet"],
                       "the Agent is off: no model there is not a problem")
        XCTAssertEqual(status.failures, [.init(provider: "soniox", feature: "dropFast", kind: "outOfCredit", minutes: 3)],
                       "a failure older than a day is gone")

        let request = try LilBroRemoteBrain.request(for: LilBroQuestion(text: "почему перестала работать диктовка",
                                                                         status: status))
        let raw = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let sent = try XCTUnwrap(body["status"] as? [String: Any])
        XCTAssertEqual(Set(sent.keys), ["permissions", "keys", "routes", "failures"])
        XCTAssertLessThan(raw.count, 600, "compact: it rides on every question")
    }

    func test_the_failure_log_keeps_the_last_failure_per_provider_and_feature() {
        let log = LilBroFailureLog()
        log.record(.busy, provider: .soniox, feature: .dropFast, at: now)
        log.record(.outOfCredit, provider: .soniox, feature: .dropFast, at: now.addingTimeInterval(10))
        log.record(.keyRefused, provider: .openAI, feature: .dropSmart, at: now.addingTimeInterval(20))
        XCTAssertEqual(log.entries.map(\.failure), [.outOfCredit, .keyRefused])
        log.clear(provider: .openAI, feature: .dropSmart)
        XCTAssertEqual(log.entries.map(\.failure), [.outOfCredit])
        log.record(.busy, provider: .deepgram, feature: .dropFast, at: now.addingTimeInterval(LilBroFailureLog.lifetime + 20))
        XCTAssertEqual(log.entries.map(\.provider), [.deepgram], "a day-old failure is dropped")
    }
}
