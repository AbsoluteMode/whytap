import Foundation

/// The request body of a finished meeting: one canonical 16 kHz mono PCM16 WAV
/// built from the recorder's chunks, between an optional prefix and suffix
/// (multipart framing). Written to disk and uploaded from there, so an hour of
/// audio is never held in memory.
enum MeetingAudioUpload {
    static let bytesPerSecond = 32_000

    /// Validates every chunk header and streams the bodies into `url` behind a
    /// single WAV header; never concatenates WAV headers. Returns the number of
    /// PCM bytes written. Rejects incompatible or corrupt recordings.
    @discardableResult
    static func write(chunkURLs: [URL], to url: URL, prefix: Data = Data(), suffix: Data = Data()) throws -> UInt64 {
        var total: UInt64 = 0
        for chunk in chunkURLs {
            try Task.checkCancellation()
            total += UInt64(try pcmBody(chunk).count)
        }
        guard total > 0, total <= UInt32.max - 36 else { throw MeetingBYOKProcessingError.noAudio }
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: prefix)
        var header = Data("RIFF".utf8)
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        append(UInt32(total) + 36)
        header.append(Data("WAVEfmt ".utf8)); append(16)
        header.append(contentsOf: [1, 0, 1, 0]); append(16000); append(32000)
        header.append(contentsOf: [2, 0, 16, 0]); header.append(Data("data".utf8)); append(UInt32(total))
        try handle.write(contentsOf: header)
        for chunk in chunkURLs {
            try Task.checkCancellation()
            try handle.write(contentsOf: pcmBody(chunk))
        }
        try handle.write(contentsOf: suffix)
        return total
    }

    private static func pcmBody(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        func uint(_ offset: Int, _ length: Int) -> UInt32 {
            (0..<length).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        guard data.count >= 44,
              data.prefix(4) == Data("RIFF".utf8), data[8..<16] == Data("WAVEfmt ".utf8),
              uint(16, 4) == 16, uint(20, 2) == 1, uint(22, 2) == 1,
              uint(24, 4) == 16000, uint(28, 4) == 32000,
              uint(32, 2) == 2, uint(34, 2) == 16,
              data[36..<40] == Data("data".utf8),
              UInt64(uint(40, 4)) == data.count - 44, (data.count - 44).isMultiple(of: 2) else {
            throw MeetingBYOKProcessingError.upstreamError("Unsupported or incomplete meeting WAV chunk.")
        }
        return Data(data.dropFirst(44))
    }
}
