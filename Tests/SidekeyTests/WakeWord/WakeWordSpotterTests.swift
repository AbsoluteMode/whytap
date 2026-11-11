import XCTest
@testable import Sidekey

final class WakeWordSpotterTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    private var model: WakeWordModel {
        WakeWordModel(directory: Self.repository.appendingPathComponent("Resources/WakeWord"))
    }

    private func tokenizer() throws -> WakeWordTokenizer {
        try XCTUnwrap(WakeWordTokenizer(sentencePieceModel: Data(contentsOf: model.sentencePiece)))
    }

    /// 16 kHz mono PCM16 wav -> samples, padded with silence like a live mic.
    private func samples(_ name: String) throws -> [Float] {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        let marker = try XCTUnwrap(data.range(of: Data("data".utf8)))
        let pcm = data[(marker.upperBound + 4)...]
        var result = [Float](repeating: 0, count: 8_000)
        pcm.withUnsafeBytes { raw in
            for index in 0..<(raw.count / 2) {
                result.append(Float(raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)) / 32_768)
            }
        }
        return result + [Float](repeating: 0, count: 16_000)
    }

    private func heard(in samples: [Float], by spotter: WakeWordSpotter) -> [String] {
        stride(from: 0, to: samples.count, by: 1_600).flatMap {
            spotter.accept(Array(samples[$0..<min($0 + 1_600, samples.count)]))
        }
    }

    func testBundledModelIsComplete() {
        XCTAssertTrue(model.isComplete)
    }

    func testTokenizerMatchesSentencePieceReference() throws {
        let tokenizer = try tokenizer()
        let reference = try JSONDecoder().decode(
            [String: [String]].self,
            from: Data(contentsOf: Self.fixtures.appendingPathComponent("sentencepiece-reference.json"))
        )
        XCTAssertGreaterThan(reference.count, 250)
        for (phrase, expected) in reference {
            XCTAssertEqual(tokenizer.tokens(for: phrase), expected, phrase)
        }
    }

    func testTokenizerNormalizesCaseAndSpacingAndRejectsUnspellablePhrases() throws {
        let tokenizer = try tokenizer()
        XCTAssertEqual(tokenizer.tokens(for: "  wait   up "), tokenizer.tokens(for: "WAIT UP"))
        XCTAssertEqual(WakeWordTokenizer.normalized("don't Stop"), "DON'T STOP")
        for phrase in ["", "   ", "вайтап", "why-tap", "tap 2", "'", "hey, you", "A\u{20DD}B", "Y\u{FE0F}ES"] {
            XCTAssertNil(tokenizer.tokens(for: phrase), phrase)
        }
    }

    func testTokenizerRejectsDataThatIsNotASentencePieceModel() {
        XCTAssertNil(WakeWordTokenizer(sentencePieceModel: Data()))
        XCTAssertNil(WakeWordTokenizer(sentencePieceModel: Data("not a model".utf8)))
        XCTAssertNil(WakeWordTokenizer(sentencePieceModel: Data([0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F])))
    }

    func testKeywordsSkipInvalidAndDuplicatePhrases() throws {
        let keywords = WakeWordKeywords(
            phrases: ["wait up", "ВАЙТАП", "Wait  Up", "why tap"], threshold: 0.1, tokenizer: try tokenizer()
        )
        XCTAssertEqual(keywords.phrases, ["WAIT UP", "WHY TAP"])
        XCTAssertEqual(
            keywords.specification,
            "\u{2581}WA IT \u{2581}UP :1.50 #0.10 @WAIT_UP\n\u{2581}WHY \u{2581}TA P :1.50 #0.10 @WHY_TAP"
        )
        XCTAssertTrue(WakeWordKeywords(phrases: ["привет"], threshold: 0.1, tokenizer: try tokenizer()).isEmpty)
    }

    func testSpotterHearsThePhraseInSpeechAndOnlyThatPhrase() throws {
        let audio = try samples("light-up.wav")
        let listening = try WakeWordSpotter(
            model: model,
            keywords: WakeWordKeywords(phrases: ["light up"], threshold: 0.25, tokenizer: try tokenizer())
        )
        XCTAssertEqual(heard(in: audio, by: listening), ["LIGHT UP"])

        let other = try WakeWordSpotter(
            model: model,
            keywords: WakeWordKeywords(phrases: ["why tap", "wait up"], threshold: 0.25, tokenizer: try tokenizer())
        )
        XCTAssertEqual(heard(in: audio, by: other), [])
    }

    func testSpotterStaysQuietOnSilenceAndHearsAgainAfterReset() throws {
        let spotter = try WakeWordSpotter(
            model: model,
            keywords: WakeWordKeywords(phrases: ["light up"], threshold: 0.25, tokenizer: try tokenizer())
        )
        XCTAssertEqual(heard(in: [Float](repeating: 0, count: 48_000), by: spotter), [])
        XCTAssertEqual(spotter.accept([]), [])
        let audio = try samples("light-up.wav")
        XCTAssertEqual(heard(in: audio, by: spotter), ["LIGHT UP"])
        spotter.reset()
        XCTAssertEqual(heard(in: audio, by: spotter), ["LIGHT UP"])
    }

    func testSpotterRefusesMissingModelAndEmptyKeywords() throws {
        let keywords = WakeWordKeywords(phrases: ["light up"], threshold: 0.25, tokenizer: try tokenizer())
        let missing = WakeWordModel(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        XCTAssertThrowsError(try WakeWordSpotter(model: missing, keywords: keywords)) {
            XCTAssertEqual($0 as? WakeWordSpotter.Failure, .modelMissing)
        }
        // Model files that drifted apart: a token the model does not list.
        let stray = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: stray) }
        for name in ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "bpe.model"] {
            try FileManager.default.copyItem(
                at: model.directory.appendingPathComponent(name), to: stray.appendingPathComponent(name)
            )
        }
        try "<blk> 0\nS 3\n".write(to: stray.appendingPathComponent("tokens.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WakeWordSpotter(model: WakeWordModel(directory: stray), keywords: keywords)) {
            XCTAssertEqual($0 as? WakeWordSpotter.Failure, .vocabularyMismatch)
        }
        let empty = WakeWordKeywords(phrases: [], threshold: 0.25, tokenizer: try tokenizer())
        XCTAssertThrowsError(try WakeWordSpotter(model: model, keywords: empty)) {
            XCTAssertEqual($0 as? WakeWordSpotter.Failure, .noKeywords)
        }
    }
}
