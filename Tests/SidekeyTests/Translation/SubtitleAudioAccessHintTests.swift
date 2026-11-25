import XCTest
@testable import Sidekey

/// Task 110: the person allowed system audio and Subtitles worked, yet the
/// overlay kept "Open audio permissions" under Stop and Settings showed "?".
/// Proof of the grant is sound a capture heard; the hint is for silence that
/// may be a refusal, never for a granted Mac that is quiet.
@MainActor
final class SubtitleAudioAccessHintTests: XCTestCase {
    private func wait(_ condition: @autoclosure () -> Bool, seconds: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func model(heard: @escaping () -> Bool, audio: FixtureSubtitleAudio,
                       session: FakeSpeechTranslation) -> LiveSubtitleModel {
        LiveSubtitleModel(flushInterval: .milliseconds(5), accessHintDelay: .milliseconds(60),
                          systemAudioHeard: heard, makeAudio: { audio }, openTranslator: { _, _ in session })
    }

    func testAQuietMacThatWasHeardBeforeNeverOffersThePrivacyPane() async throws {
        let audio = FixtureSubtitleAudio()
        let model = model(heard: { true }, audio: audio, session: FakeSpeechTranslation())
        model.start()
        try await wait(model.phase == .listening)
        audio.pair.continuation.yield([Float](repeating: 0, count: 2_400))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.phase, .listening)
        XCTAssertFalse(model.hasAudio)
        XCTAssertFalse(model.silenceMayMeanNoAccess, "the grant is proven: silence is just a quiet Mac")
        await model.cancel().value
    }

    func testSilenceBeforeAnySoundWasEverHeardOffersThePaneOnlyAfterTheDelay() async throws {
        let audio = FixtureSubtitleAudio()
        let model = model(heard: { false }, audio: audio, session: FakeSpeechTranslation())
        model.start()
        try await wait(model.phase == .listening)
        XCTAssertFalse(model.silenceMayMeanNoAccess, "not at the first moment of listening")
        audio.pair.continuation.yield([Float](repeating: 0, count: 2_400))
        try await wait(model.silenceMayMeanNoAccess)
        XCTAssertTrue(model.silenceMayMeanNoAccess)
        await model.cancel().value
    }

    func testTheFirstSoundRemovesTheHint() async throws {
        let audio = FixtureSubtitleAudio()
        let model = model(heard: { false }, audio: audio, session: FakeSpeechTranslation())
        model.start()
        try await wait(model.phase == .listening)
        try await wait(model.silenceMayMeanNoAccess)
        XCTAssertTrue(model.silenceMayMeanNoAccess)
        audio.pair.continuation.yield([Float](repeating: 0.2, count: 2_400))
        try await wait(model.hasAudio)
        XCTAssertFalse(model.silenceMayMeanNoAccess)
        await model.cancel().value
    }

    func testSoundBeforeTheDelayMeansNoHintAtAll() async throws {
        let audio = FixtureSubtitleAudio()
        let model = model(heard: { false }, audio: audio, session: FakeSpeechTranslation())
        model.start()
        try await wait(model.phase == .listening)
        audio.pair.continuation.yield([Float](repeating: 0.2, count: 2_400))
        try await wait(model.hasAudio)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.silenceMayMeanNoAccess)
        await model.cancel().value
    }

    /// A capture elsewhere (a meeting, the detector) can prove the grant
    /// while Subtitles wait: the hint is checked again when it is due.
    func testAGrantProvenWhileWaitingCancelsTheHint() async throws {
        let audio = FixtureSubtitleAudio()
        var heard = false
        let model = model(heard: { heard }, audio: audio, session: FakeSpeechTranslation())
        model.start()
        try await wait(model.phase == .listening)
        heard = true
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(model.silenceMayMeanNoAccess)
        await model.cancel().value
    }

    func testANewStartClearsAnOldHint() async throws {
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), accessHintDelay: .milliseconds(30),
                                      systemAudioHeard: { false }, makeAudio: { FixtureSubtitleAudio() },
                                      openTranslator: { _, _ in FakeSpeechTranslation() })
        model.start()
        try await wait(model.silenceMayMeanNoAccess)
        XCTAssertTrue(model.silenceMayMeanNoAccess)
        await model.cancel().value
        model.start()
        XCTAssertFalse(model.silenceMayMeanNoAccess, "Start begins without the hint")
        await model.cancel().value
    }
}

/// The remembered proof itself.
final class SystemAudioAccessTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "system-audio-access-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testNothingHeardUntilRecordedThenRememberedForGood() {
        XCTAssertFalse(SystemAudioAccess.heard(defaults: defaults))
        SystemAudioAccess.recordHeard(defaults: defaults)
        XCTAssertTrue(SystemAudioAccess.heard(defaults: defaults))
        XCTAssertTrue(UserDefaults(suiteName: suite)!.bool(forKey: SystemAudioAccess.heardKey), "persisted")
    }

    func testOnlyTheFirstRecordNotifiesSettings() {
        // Posts queued by earlier tests arrive first, outside the count.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var count = 0
        let observer = NotificationCenter.default.addObserver(
            forName: SystemAudioAccess.didChange, object: nil, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        SystemAudioAccess.recordHeard(defaults: defaults)
        SystemAudioAccess.recordHeard(defaults: defaults)
        SystemAudioAccess.recordHeard(defaults: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(count, 1)
    }

    /// A refused grant delivers exact zeros; any sound at all is the proof.
    func testOnlyExactSilenceIsNotASignal() {
        XCTAssertFalse(SystemAudioAccess.containsSignal([]))
        XCTAssertFalse(SystemAudioAccess.containsSignal([Float](repeating: 0, count: 512)))
        XCTAssertFalse(SystemAudioAccess.containsSignal([0, -0, 0]))
        XCTAssertTrue(SystemAudioAccess.containsSignal([0, 0, -0.0001, 0]))
        XCTAssertTrue(SystemAudioAccess.containsSignal([Float](repeating: 0, count: 511) + [1e-7]))
    }
}
