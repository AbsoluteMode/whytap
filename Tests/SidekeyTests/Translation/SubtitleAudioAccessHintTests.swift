import CoreAudio
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

    /// Queue review 555, 1: the hint is already shown when a meeting or the
    /// detector proves the grant; it goes away without this capture's sound.
    func testAProofFromAnotherCaptureClearsAnAlreadyVisibleHint() async throws {
        let audio = FixtureSubtitleAudio()
        var heard = false
        let model = model(heard: { heard }, audio: audio, session: FakeSpeechTranslation())
        model.start()
        try await wait(model.silenceMayMeanNoAccess)
        XCTAssertTrue(model.silenceMayMeanNoAccess)
        heard = true
        NotificationCenter.default.post(name: SystemAudioAccess.didChange, object: nil)
        try await wait(!model.silenceMayMeanNoAccess)
        XCTAssertFalse(model.silenceMayMeanNoAccess)
        XCTAssertFalse(model.hasAudio, "this capture still heard nothing")
        XCTAssertEqual(model.phase, .listening)
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

    /// Queue review 555, 3: two captures' first callbacks at once write and
    /// notify Settings once.
    func testConcurrentFirstProofsNotifyOnce() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var count = 0
        let observer = NotificationCenter.default.addObserver(
            forName: SystemAudioAccess.didChange, object: nil, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let defaults = self.defaults!
        for _ in 0..<20 {
            defaults.removeObject(forKey: SystemAudioAccess.heardKey)
            count = 0
            DispatchQueue.concurrentPerform(iterations: 16) { _ in SystemAudioAccess.recordHeard(defaults: defaults) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(count, 1)
        }
    }
}

/// Queue review 555, 2: the proof is measured on the delivered PCM, before
/// channels are mixed to mono.
final class SystemAudioInputSignalTests: XCTestCase {
    private func format(float: Bool, planar: Bool, channels: UInt32 = 2) -> AudioStreamBasicDescription {
        var flags: AudioFormatFlags = float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
        if planar { flags |= kAudioFormatFlagIsNonInterleaved }
        let bits: UInt32 = float ? 32 : 16
        let frameBytes = planar ? bits / 8 : bits / 8 * channels
        return AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: frameBytes, mFramesPerPacket: 1, mBytesPerFrame: frameBytes,
            mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
    }

    /// Builds an AudioBufferList over `buffers` (one per plane, or one
    /// interleaved) and runs `body` with it.
    private func withList(_ buffers: [[UInt8]], channelsPerBuffer: UInt32,
                             _ body: (UnsafePointer<AudioBufferList>) -> Bool) -> Bool {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(list.unsafeMutablePointer) }
        var storage = buffers.map { bytes -> UnsafeMutableRawPointer in
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 16)
            bytes.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
            return pointer
        }
        defer { storage.forEach { $0.deallocate() }; storage.removeAll() }
        for (index, bytes) in buffers.enumerated() {
            list[index] = AudioBuffer(mNumberChannels: channelsPerBuffer, mDataByteSize: UInt32(bytes.count),
                                      mData: storage[index])
        }
        return body(UnsafePointer(list.unsafePointer))
    }

    private func bytes(_ samples: [Float]) -> [UInt8] { samples.withUnsafeBytes { Array($0) } }
    private func bytes(_ samples: [Int16]) -> [UInt8] { samples.withUnsafeBytes { Array($0) } }

    func testOppositeInterleavedStereoIsSoundThoughItMixesToSilence() {
        let frames = (0..<256).flatMap { _ in [Float(0.25), Float(-0.25)] }
        XCTAssertTrue(withList([bytes(frames)], channelsPerBuffer: 2) {
            CoreAudioSystemAudioSource.inputContainsSignal($0, format: format(float: true, planar: false))
        })
    }

    func testOppositePlanarStereoIsSound() {
        let left = [Float](repeating: 0.25, count: 256), right = [Float](repeating: -0.25, count: 256)
        XCTAssertTrue(withList([bytes(left), bytes(right)], channelsPerBuffer: 1) {
            CoreAudioSystemAudioSource.inputContainsSignal($0, format: format(float: true, planar: true))
        })
    }

    func testOppositeIntegerStereoIsSound() {
        let frames = (0..<256).flatMap { _ in [Int16(8_000), Int16(-8_000)] }
        XCTAssertTrue(withList([bytes(frames)], channelsPerBuffer: 2) {
            CoreAudioSystemAudioSource.inputContainsSignal($0, format: format(float: false, planar: false))
        })
    }

    /// A refused grant delivers exact zeros, in every layout.
    func testExactZerosAreNotSound() {
        let zeros = [Float](repeating: 0, count: 512)
        XCTAssertFalse(withList([bytes(zeros)], channelsPerBuffer: 2) {
            CoreAudioSystemAudioSource.inputContainsSignal($0, format: format(float: true, planar: false))
        })
        XCTAssertFalse(withList([bytes(zeros), bytes(zeros)], channelsPerBuffer: 1) {
            CoreAudioSystemAudioSource.inputContainsSignal($0, format: format(float: true, planar: true))
        })
        XCTAssertFalse(withList([bytes([Int16](repeating: 0, count: 512))], channelsPerBuffer: 2) {
            CoreAudioSystemAudioSource.inputContainsSignal($0, format: format(float: false, planar: false))
        })
    }

    func testOneQuietSampleInOneChannelIsSound() {
        var right = [Float](repeating: 0, count: 256); right[200] = 1e-6
        XCTAssertTrue(withList([bytes([Float](repeating: 0, count: 256)), bytes(right)], channelsPerBuffer: 1) {
            CoreAudioSystemAudioSource.inputContainsSignal($0, format: format(float: true, planar: true))
        })
    }
}
