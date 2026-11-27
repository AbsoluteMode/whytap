import Foundation

enum AIUsageTaskScope {
    @TaskLocal static var context: AIUsageContext?
}

enum AIUsageAudio {
    /// WAV data chunks, not file size: optional metadata and padding are not audio.
    static func wavSeconds(_ data: Data) -> Double? {
        guard data.count >= 44, String(decoding: data.prefix(4), as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        func u32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        var offset = 12, bytesPerSecond = 0, audioBytes = 0
        while offset + 8 <= data.count {
            let size = u32(offset + 4), end = offset + 8 + size
            guard end <= data.count else { return nil }
            let name = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            if name == "fmt ", size >= 16 { bytesPerSecond = u32(offset + 16) }
            if name == "data" { audioBytes += size }
            offset = end + size % 2
        }
        guard bytesPerSecond > 0 else { return nil }
        return Double(audioBytes) / Double(bytesPerSecond)
    }
}

/// A pass-through wrapper: no extra socket, event consumer, finalization or
/// cancellation. The route is captured before audio leaves the machine.
struct AIUsageMeteredAdapter: BYOKTranscriptionAdapter {
    let adapter: BYOKTranscriptionAdapter
    let context: AIUsageContext
    var record: (AIUsageEvent) -> Void = AIUsageRecorder.record
    func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession {
        let upstream = try await adapter.open(language: language, terms: terms)
        return AIUsageMeteredSession(upstream: upstream, context: context, record: record)
    }
}

final class AIUsageMeteredSession: BYOKUpstreamSession {
    let upstream: BYOKUpstreamSession
    let context: AIUsageContext
    let record: (AIUsageEvent) -> Void
    private let lock = NSLock()
    private let started = Date()
    private var bytes = 0
    private var recorded = false
    init(upstream: BYOKUpstreamSession, context: AIUsageContext, record: @escaping (AIUsageEvent) -> Void) {
        self.upstream = upstream; self.context = context; self.record = record
    }
    var events: AsyncStream<BYOKStreamEvent> { upstream.events }
    var finalsJoin: BYOKTranscriptJoin { upstream.finalsJoin }
    var partialsSpanSegment: Bool { upstream.partialsSpanSegment }
    var emitsPartialAfterFrameFinals: Bool { upstream.emitsPartialAfterFrameFinals }
    func sendAudio(_ pcm: Data) async {
        lock.withLock { if !recorded { bytes += pcm.count } }
        await upstream.sendAudio(pcm)
    }
    func endInput() async { await upstream.endInput() }
    func close() async {
        let count: Int? = lock.withLock {
            guard !recorded else { return nil }
            recorded = true; return bytes
        }
        if let count, count > 0 {
            let snapshot = await upstream.usageSnapshot()
            let seconds = Double(snapshot?.acceptedAudioBytes ?? count) / 32_000
            var event = AIUsageEvent.speech(context, seconds: seconds, at: started)
            if snapshot?.failed == true {
                event = AIUsageEvent(createdAt: started, context: context, currency: context.currency,
                                     amount: nil, basis: .unavailable, audioSeconds: seconds)
            }
            if [.elevenLabs, .soniox].contains(context.account), let reference = snapshot?.providerReference,
               !reference.isEmpty, reference.count <= 256 {
                event.id = (context.account == .soniox ? "soniox:" : "elevenlabs:") + reference
            }
            record(event)
        }
        await upstream.close()
    }
}
