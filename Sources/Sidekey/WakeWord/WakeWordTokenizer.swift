import Foundation

/// Turns a wake phrase into the model's subword tokens, in Swift, so a phrase
/// typed in Settings needs no Python tooling. The keyword spotter takes token
/// sequences, not text, and has no text-to-token call in its C API.
///
/// The bundled `bpe.model` is a SentencePiece unigram model: the encoding of a
/// word is the segmentation with the highest total piece score (Viterbi).
/// Verified equal to SentencePiece on 50,000 random phrases.
/// WHY: .project-docs/decisions/2026-11-11-wake-word.md
struct WakeWordTokenizer {
    private let scores: [String: Float]
    private let longestPiece: Int

    private static let wordBoundary: Character = "\u{2581}"

    /// - Parameter sentencePieceModel: contents of the model's `bpe.model`.
    init?(sentencePieceModel data: Data) {
        guard let pieces = Self.normalPieces(in: data), !pieces.isEmpty else { return nil }
        scores = pieces
        longestPiece = pieces.keys.map(\.count).max() ?? 1
    }

    /// Uppercased, single-spaced phrase, or nil when it has characters the
    /// English model cannot spell (anything but A-Z and apostrophes).
    static func normalized(_ phrase: String) -> String? {
        let words = phrase.uppercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        // Scalars, not Characters: a letter with a combining mark compares
        // inside "A"..."Z" as a Character but is not in the vocabulary.
        for word in words {
            let scalars = word.unicodeScalars
            guard scalars.allSatisfy({ ("A"..."Z").contains($0) || $0 == "'" }) else { return nil }
            guard scalars.contains(where: { ("A"..."Z").contains($0) }) else { return nil }
        }
        return words.joined(separator: " ")
    }

    /// Tokens of a normalized phrase, or nil when it cannot be encoded.
    func tokens(for phrase: String) -> [String]? {
        guard let normalized = Self.normalized(phrase) else { return nil }
        var result: [String] = []
        for word in normalized.split(separator: " ") {
            guard let pieces = segment(Array(String(Self.wordBoundary) + word)) else { return nil }
            result += pieces
        }
        return result
    }

    private func segment(_ characters: [Character]) -> [String]? {
        let count = characters.count
        var best = [Float](repeating: -.infinity, count: count + 1)
        var previous = [Int](repeating: -1, count: count + 1)
        best[0] = 0
        for start in 0..<count where best[start] > -.infinity {
            for end in (start + 1)...min(count, start + longestPiece) {
                guard let score = scores[String(characters[start..<end])] else { continue }
                if best[start] + score > best[end] {
                    best[end] = best[start] + score
                    previous[end] = start
                }
            }
        }
        guard best[count] > -.infinity else { return nil }
        var pieces: [String] = []
        var end = count
        while end > 0 {
            let start = previous[end]
            pieces.append(String(characters[start..<end]))
            end = start
        }
        return pieces.reversed()
    }

    // MARK: - SentencePiece ModelProto (protobuf) reader

    /// `ModelProto.pieces` (field 1), each `{1: piece, 2: score, 3: type}`.
    /// Only NORMAL pieces (type 1, the default) take part in encoding.
    private static func normalPieces(in data: Data) -> [String: Float]? {
        var reader = ProtobufReader(bytes: [UInt8](data))
        var result: [String: Float] = [:]
        while !reader.isAtEnd {
            guard let (field, wire) = reader.readTag() else { return nil }
            if field == 1, wire == 2 {
                guard let body = reader.readLengthDelimited() else { return nil }
                var piece = ProtobufReader(bytes: body)
                var text: String?
                var score: Float = 0
                var type: UInt64 = 1
                while !piece.isAtEnd {
                    guard let (pieceField, pieceWire) = piece.readTag() else { return nil }
                    switch (pieceField, pieceWire) {
                    case (1, 2):
                        guard let bytes = piece.readLengthDelimited() else { return nil }
                        text = String(decoding: bytes, as: UTF8.self)
                    case (2, 5):
                        guard let bits = piece.readFixed32() else { return nil }
                        score = Float(bitPattern: bits)
                    case (3, 0):
                        guard let value = piece.readVarint() else { return nil }
                        type = value
                    default:
                        guard piece.skip(wire: pieceWire) else { return nil }
                    }
                }
                if let text, type == 1 { result[text] = score }
            } else {
                guard reader.skip(wire: wire) else { return nil }
            }
        }
        return result
    }

    private struct ProtobufReader {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while offset < bytes.count, shift < 64 {
                let byte = bytes[offset]
                offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        mutating func readTag() -> (field: UInt64, wire: UInt64)? {
            guard let tag = readVarint() else { return nil }
            return (tag >> 3, tag & 7)
        }

        mutating func readLengthDelimited() -> [UInt8]? {
            guard let length = readVarint(), length <= UInt64(bytes.count - offset) else { return nil }
            defer { offset += Int(length) }
            return Array(bytes[offset..<(offset + Int(length))])
        }

        mutating func readFixed32() -> UInt32? {
            guard bytes.count - offset >= 4 else { return nil }
            defer { offset += 4 }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }

        mutating func skip(wire: UInt64) -> Bool {
            switch wire {
            case 0: return readVarint() != nil
            case 1:
                guard bytes.count - offset >= 8 else { return false }
                offset += 8
                return true
            case 2: return readLengthDelimited() != nil
            case 5: return readFixed32() != nil
            default: return false
            }
        }
    }
}
