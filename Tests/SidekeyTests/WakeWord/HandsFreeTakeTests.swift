import XCTest
@testable import Sidekey

/// A wake-word take has no key release: on a model that predicts turns the
/// provider ends it, and the app must treat that as a normal finish.
@MainActor
final class HandsFreeTakeTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - ElevenLabs URL

    func testHandsFreeAsksForTurnPredictionOnlyOnAModelThatHasIt() {
        XCTAssertTrue(ElevenLabsRealtimeURL.supportsTurnPrediction(model: "scribe_v3_live"))
        XCTAssertFalse(ElevenLabsRealtimeURL.supportsTurnPrediction(model: "scribe_v2_realtime"))

        let handsFree = query(ElevenLabsRealtimeURL.make(
            model: "scribe_v3_live", language: "ru", terms: ["Whytap"], providerEndsTurn: true
        ))
        XCTAssertEqual(handsFree["commit_strategy"], "turn_prediction")
        XCTAssertEqual(handsFree["vad_silence_threshold_secs"], "1.50")
        let tuned = query(ElevenLabsRealtimeURL.make(
            model: "scribe_v3_live", language: nil, terms: [], providerEndsTurn: true, turnSilenceSeconds: 0.8
        ))
        XCTAssertEqual(tuned["vad_silence_threshold_secs"], "0.80")
        XCTAssertEqual(handsFree["model_id"], "scribe_v3_live")
        XCTAssertEqual(handsFree["language_code"], "ru")
        XCTAssertEqual(handsFree["no_verbatim"], "true")

        let held = query(ElevenLabsRealtimeURL.make(model: "scribe_v3_live", language: nil, terms: []))
        XCTAssertEqual(held["commit_strategy"], "manual")
        XCTAssertNil(held["vad_silence_threshold_secs"])
    }

    func testHandsFreeOnAnOlderModelStaysManual() {
        XCTAssertFalse(ElevenLabsBYOKAdapter(apiKey: "k", model: "scribe_v2_realtime", handsFree: true).endsTurnItself)
        XCTAssertTrue(ElevenLabsBYOKAdapter(apiKey: "k", model: "scribe_v3_live", handsFree: true).endsTurnItself)
        XCTAssertFalse(ElevenLabsBYOKAdapter(apiKey: "k", model: "scribe_v3_live").endsTurnItself)
    }

    // MARK: - ElevenLabs commits

    func testProviderCommitWithWordsEndsAHandsFreeTake() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v3_live", providerEndsTurn: true) { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        var events = session.events.makeAsyncIterator()

        // Silence before speech can be committed empty: keep listening.
        stub.deliverText(#"{"message_type":"committed_transcript","text":"  "}"#)
        let empty = await events.next()
        XCTAssertEqual(empty, .final("  "))
        stub.deliverText(#"{"message_type":"partial_transcript","text":"напиши"}"#)
        let partial = await events.next()
        XCTAssertEqual(partial, .partial("напиши"))

        stub.deliverText(#"{"message_type":"committed_transcript","text":"Напиши письмо."}"#)
        let final = await events.next()
        XCTAssertEqual(final, .final("Напиши письмо."))
        let done = await events.next()
        XCTAssertEqual(done, .done("Напиши письмо."))
        let end = await events.next()
        XCTAssertNil(end)
        await session.close()
    }

    /// A dropped connection is not the speaker finishing: it must surface as
    /// a transport error so the retained audio is recovered, whatever was
    /// committed before.
    func testSocketCloseDuringAHandsFreeTakeIsAnErrorNotATurnEnd() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v3_live", providerEndsTurn: true) { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        var events = session.events.makeAsyncIterator()
        stub.deliverText(#"{"message_type":"committed_transcript","text":""}"#)
        let empty = await events.next()
        XCTAssertEqual(empty, .final(""))
        stub.deliverText(#"{"message_type":"partial_transcript","text":"напиши пись"}"#)
        let partial = await events.next()
        XCTAssertEqual(partial, .partial("напиши пись"))
        stub.deliver(.failure(URLError(.networkConnectionLost)))
        let closed = await events.next()
        XCTAssertEqual(closed, .error("transport"))
        await session.close()
    }

    func testHeldTakeStillIgnoresProviderCommitsUntilRelease() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v3_live") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        var events = session.events.makeAsyncIterator()
        stub.deliverText(#"{"message_type":"committed_transcript","text":"первая часть"}"#)
        let first = await events.next()
        XCTAssertEqual(first, .final("первая часть"))
        stub.deliverText(#"{"message_type":"partial_transcript","text":"вторая"}"#)
        let next = await events.next()
        XCTAssertEqual(next, .partial("вторая"))  // not .done: the take goes on
        await session.close()
    }

    // MARK: - Session result

    private struct TurnEndingAdapter: BYOKTranscriptionAdapter {
        let session: DirectProviderStreamingSessionTests.FakeSession
        let endsTurnItself: Bool
        func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession { session }
    }

    private func result(endsTurnItself: Bool, stopFirst: Bool) async -> StreamingSessionResult {
        let upstream = DirectProviderStreamingSessionTests.FakeSession()
        let session = DirectProviderStreamingSession(
            audioEngine: DirectProviderStreamingSessionTests.FakeAudio(),
            adapter: TurnEndingAdapter(session: upstream, endsTurnItself: endsTurnItself),
            language: nil, terms: []
        )
        let run = Task { await session.run() }
        try? await Task.sleep(for: .milliseconds(30))
        if stopFirst {
            await session.stop()
            try? await Task.sleep(for: .milliseconds(30))
        }
        upstream.cont.yield(.done("готово"))
        return await run.value
    }

    func testProviderEndedTurnResolvesAsEndpointNotAbnormalClose() async {
        let handsFree = await result(endsTurnItself: true, stopFirst: false)
        XCTAssertEqual(handsFree, .endpointDetected("готово"))
        // `.endpointDetected` always delivers its text (DropDeliveryResolverTests).
    }

    func testOrdinaryTakesKeepResolvingAsTranscript() async {
        let ordinary = await result(endsTurnItself: false, stopFirst: false)
        XCTAssertEqual(ordinary, .transcript("готово"))
        let stopped = await result(endsTurnItself: true, stopFirst: true)
        XCTAssertEqual(stopped, .transcript("готово"))
    }

    // MARK: - Factory

    func testOnlyAHandsFreeTakeUsesTheHandsFreeAdapterOnTheSameRoute() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let routing = AIRoutingStore(defaults: defaults)
        let tokens = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: tokens) })
        routing.setRoute(FeatureRoute(account: .elevenLabs, model: "scribe_v3_live"), for: .dropFast)
        try keys.save("key", account: try XCTUnwrap(ProviderAccount.elevenLabs.keychainAccount(in: routing)))

        var ordinary: [ResolvedRoute] = []
        var handsFree: [ResolvedRoute] = []
        let factory = TranscriptionSessionFactory(
            resolver: FeatureRouteResolver(routing: routing, keys: keys),
            vocab: VocabularyCache(defaults: UserDefaults(suiteName: "vocab.\(UUID().uuidString)")!),
            makeAdapter: { ordinary.append($0); return try RealtimeAdapterFactory.make($0) },
            makeHandsFreeAdapter: { handsFree.append($0); return try RealtimeAdapterFactory.makeMeteredHandsFree($0) }
        )
        _ = try factory.make(feature: .dropFast, language: nil, resilient: true)
        XCTAssertEqual(ordinary.count, 1)
        XCTAssertTrue(handsFree.isEmpty)

        _ = try factory.make(feature: .dropFast, language: nil, resilient: true, handsFree: true)
        XCTAssertEqual(handsFree.count, 1)
        XCTAssertEqual(handsFree.first?.model, "scribe_v3_live")
        XCTAssertEqual(handsFree.first?.account, .elevenLabs)
        XCTAssertTrue(try RealtimeAdapterFactory.makeMeteredHandsFree(try XCTUnwrap(handsFree.first)).endsTurnItself)
        XCTAssertFalse(try RealtimeAdapterFactory.makeMetered(try XCTUnwrap(handsFree.first)).endsTurnItself)
    }
}
