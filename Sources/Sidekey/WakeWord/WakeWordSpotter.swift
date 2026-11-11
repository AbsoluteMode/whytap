import Foundation
import SherpaOnnxC

/// The bundled keyword-spotting model (Resources/WakeWord).
struct WakeWordModel: Equatable {
    let directory: URL

    var encoder: URL { directory.appendingPathComponent("encoder.int8.onnx") }
    var decoder: URL { directory.appendingPathComponent("decoder.int8.onnx") }
    var joiner: URL { directory.appendingPathComponent("joiner.int8.onnx") }
    var tokens: URL { directory.appendingPathComponent("tokens.txt") }
    var sentencePiece: URL { directory.appendingPathComponent("bpe.model") }

    var isComplete: Bool {
        [encoder, decoder, joiner, tokens, sentencePiece]
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The copy packaged into the app bundle, or nil in a build without it.
    static var bundled: WakeWordModel? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let model = WakeWordModel(directory: resources.appendingPathComponent("WakeWord", isDirectory: true))
        return model.isComplete ? model : nil
    }
}

/// What the spotter listens for: phrases as the model hears them, with one
/// detection threshold. A phrase the model cannot spell is skipped.
struct WakeWordKeywords: Equatable {
    /// Bonus applied to keyword paths during search; the model card's default
    /// range is 1-2 and 1.5 matched the user's own measurements.
    static let boost: Float = 1.5

    private(set) var phrases: [String]
    let specification: String
    /// Every subword token the specification names.
    let tokens: Set<String>

    init(phrases: [String], threshold: Float, tokenizer: WakeWordTokenizer) {
        var accepted: [String] = []
        var lines: [String] = []
        var used: Set<String> = []
        for phrase in phrases {
            guard let normalized = WakeWordTokenizer.normalized(phrase),
                  !accepted.contains(normalized),
                  let tokens = tokenizer.tokens(for: normalized) else { continue }
            accepted.append(normalized)
            used.formUnion(tokens)
            let label = normalized.replacingOccurrences(of: " ", with: "_")
            lines.append(
                "\(tokens.joined(separator: " ")) :\(String(format: "%.2f", Self.boost))"
                    + " #\(String(format: "%.2f", threshold)) @\(label)"
            )
        }
        self.phrases = accepted
        self.tokens = used
        specification = lines.joined(separator: "\n")
    }

    var isEmpty: Bool { phrases.isEmpty }
}

/// Streaming keyword spotter over the sherpa-onnx C API. Runs entirely on this
/// Mac; audio handed to `accept` is never stored. Not thread-safe: one owner
/// feeds it from one queue.
final class WakeWordSpotter {
    enum Failure: Error, Equatable {
        case modelMissing
        case noKeywords
        case engineUnavailable
        /// The phrases use a token the model's `tokens.txt` does not list.
        case vocabularyMismatch
    }

    static let sampleRate: Int32 = 16_000

    private let spotter: OpaquePointer
    private var stream: OpaquePointer

    init(model: WakeWordModel, keywords: WakeWordKeywords) throws {
        guard model.isComplete else { throw Failure.modelMissing }
        guard !keywords.isEmpty else { throw Failure.noKeywords }
        // The engine may end the process on a token it does not know, so
        // model files that drifted apart are refused here instead.
        guard let listing = try? String(contentsOf: model.tokens, encoding: .utf8) else {
            throw Failure.modelMissing
        }
        let known = Set(listing.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
        guard keywords.tokens.isSubset(of: known) else { throw Failure.vocabularyMismatch }

        // The C structs keep borrowed pointers only for the duration of the
        // create call, so every string is kept alive by this scope.
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func cString(_ value: String) -> UnsafePointer<CChar> {
            let pointer = strdup(value)!
            strings.append(pointer)
            return UnsafePointer(pointer)
        }

        var config = SherpaOnnxKeywordSpotterConfig()
        config.feat_config = SherpaOnnxFeatureConfig(sample_rate: Self.sampleRate, feature_dim: 80)
        config.model_config.transducer.encoder = cString(model.encoder.path)
        config.model_config.transducer.decoder = cString(model.decoder.path)
        config.model_config.transducer.joiner = cString(model.joiner.path)
        config.model_config.tokens = cString(model.tokens.path)
        config.model_config.num_threads = 1
        config.model_config.provider = cString("cpu")
        config.max_active_paths = 4
        config.num_trailing_blanks = 1
        config.keywords_score = 1
        config.keywords_threshold = 0.25
        config.keywords_buf = cString(keywords.specification)
        config.keywords_buf_size = Int32(keywords.specification.utf8.count)

        guard let spotter = SherpaOnnxCreateKeywordSpotter(&config),
              let stream = SherpaOnnxCreateKeywordStream(spotter) else {
            throw Failure.engineUnavailable
        }
        self.spotter = spotter
        self.stream = stream
    }

    deinit {
        SherpaOnnxDestroyOnlineStream(stream)
        SherpaOnnxDestroyKeywordSpotter(spotter)
    }

    /// Feeds 16 kHz mono samples in [-1, 1]; returns the phrases heard in them.
    func accept(_ samples: [Float]) -> [String] {
        guard !samples.isEmpty else { return [] }
        samples.withUnsafeBufferPointer {
            SherpaOnnxOnlineStreamAcceptWaveform(stream, Self.sampleRate, $0.baseAddress, Int32($0.count))
        }
        var heard: [String] = []
        while SherpaOnnxIsKeywordStreamReady(spotter, stream) != 0 {
            SherpaOnnxDecodeKeywordStream(spotter, stream)
            guard let result = SherpaOnnxGetKeywordResult(spotter, stream) else { continue }
            let keyword = String(cString: result.pointee.keyword)
            SherpaOnnxDestroyKeywordResult(result)
            guard !keyword.isEmpty else { continue }
            heard.append(keyword.replacingOccurrences(of: "_", with: " "))
            // Without a reset the same keyword keeps firing on later frames.
            SherpaOnnxResetKeywordStream(spotter, stream)
        }
        return heard
    }

    /// Drops buffered audio and decoder state, e.g. after a pause.
    func reset() {
        guard let fresh = SherpaOnnxCreateKeywordStream(spotter) else { return }
        SherpaOnnxDestroyOnlineStream(stream)
        stream = fresh
    }
}
