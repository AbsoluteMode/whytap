import XCTest
@testable import Sidekey

@MainActor
final class TranscriptionSessionFactoryTests: XCTestCase {
    private func prefs(_ level: TranscriptionIsolationLevel, _ provider: BYOKProvider = .soniox) -> SelfKeyPreferences {
        let d = UserDefaults(suiteName: "factory.test.\(UUID().uuidString)")!
        let p = SelfKeyPreferences(defaults: d)
        p.transcriptionLevel = level
        p.selectedProvider = provider
        return p
    }

    private func vocab() -> VocabularyCache {
        VocabularyCache(defaults: UserDefaults(suiteName: "v\(UUID())")!)
    }

    func testYourKeyBuildsDirectSessionForEachProvider() throws {
        // OpenAI dropped from BYOK (migrates to soniox); exercise the remaining
        // hosted providers. Keys live in an in-memory store: the suite never
        // reads or writes the user's real Keychain items.
        for provider in [BYOKProvider.deepgram, .soniox, .elevenLabs] {
            let kc = BYOKKeyStore.inMemory()
            try kc.save(key: "key-\(provider.rawValue)", for: provider)
            let factory = TranscriptionSessionFactory(prefs: prefs(.yourKey, provider), keyStore: kc, vocab: vocab())
            let session = try factory.make(language: "en")
            XCTAssertTrue(session is DirectProviderStreamingSession, "expected DirectProviderStreamingSession for \(provider)")
        }
    }

    func testYourKeyWithoutKeyThrows() throws {
        for provider in [BYOKProvider.deepgram, .soniox, .elevenLabs] {
            let factory = TranscriptionSessionFactory(prefs: prefs(.yourKey, provider), keyStore: .inMemory(), vocab: vocab())
            XCTAssertThrowsError(try factory.make(language: "en"), "expected throw for \(provider) without key") { error in
                XCTAssertEqual(error as? TranscriptionFactoryError, .missingKey)
            }
        }
    }

    func testSelfHostedWithoutBaseURLThrows() throws {
        let kc = BYOKKeyStore.inMemory()
        try kc.save(key: "key-selfHosted", for: .selfHosted)
        let p = prefs(.yourKey, .selfHosted)
        p.selfHostedBaseURL = nil
        let factory = TranscriptionSessionFactory(prefs: p, keyStore: kc, vocab: vocab())
        XCTAssertThrowsError(try factory.make(language: "en")) { error in
            XCTAssertEqual(error as? TranscriptionFactoryError, .missingBaseURL)
        }
    }

    func testLocalBuildsLocalSession() throws {
        let factory = TranscriptionSessionFactory(
            prefs: prefs(.local),
            keyStore: .inMemory(),
            vocab: vocab()
        )
        let session = try factory.make(language: "en")
        XCTAssertTrue(session is LocalTranscriptionSession)
    }

    func testDefaultTranscriptionModelPerProvider() {
        XCTAssertEqual(BYOKProvider.openAI.defaultTranscriptionModel, "gpt-4o-transcribe")
        XCTAssertEqual(BYOKProvider.selfHosted.defaultTranscriptionModel, "gpt-4o-transcribe")
        XCTAssertEqual(BYOKProvider.deepgram.defaultTranscriptionModel, "nova-3")
        XCTAssertEqual(BYOKProvider.soniox.defaultTranscriptionModel, "stt-rt-v5")
        XCTAssertEqual(BYOKProvider.elevenLabs.defaultTranscriptionModel, "scribe_v2_realtime")
    }

    // MARK: - Resilient scoping in the factory (source inspection)
    //
    // `make(language:resilient:)` is a small factory; behavioral tests can't
    // easily observe `resilient` on the returned session without driving the
    // session with a real or stub adapter. Source inspection pins the call-site
    // wiring structurally so any drift fails with an actionable message.
    //
    // CONTRACT: the `.yourKey` BYOK branch passes `resilient: resilient` so
    // the Drop flag threads through to `DirectProviderStreamingSession` and a
    // degraded BYOK turn keeps its PCM for the on-device batch recovery rung.

    func testBYOKBranchPassesResilientToDirectProviderSession() throws {
        let source = try factorySource()
        XCTAssertTrue(
            source.contains("resilient: resilient"),
            "BYOK DirectProviderStreamingSession init must pass `resilient: resilient` so the Drop flag threads through."
        )
    }

    private func factorySource() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let factoryURL = candidate.deletingLastPathComponent()
                    .appendingPathComponent("Sources")
                    .appendingPathComponent("Sidekey")
                    .appendingPathComponent("Streaming")
                    .appendingPathComponent("BYOK")
                    .appendingPathComponent("TranscriptionSessionFactory.swift")
                return try String(contentsOf: factoryURL, encoding: .utf8)
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "TranscriptionSessionFactoryTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate Package.swift"])
    }
}
