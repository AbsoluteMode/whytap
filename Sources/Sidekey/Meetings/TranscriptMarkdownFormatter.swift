import Foundation

/// Turns a diarized `[TranscriptSegment]` into the markdown shape the
/// meeting Transcribe tab feeds to BlockNote. Mirrors the format the
/// summaries used to inline at the bottom of `note.markdown` ("## Transcript"
/// section), so the new dedicated tab visually matches what users
/// already saw inside their summary.
///
/// Format:
///
/// ```
/// **Speaker 1 [00:02-00:04]:** Алло.
///
/// **Speaker 2 [00:03-00:06]:** Доброе утро.
/// ```
///
/// Pure function — no I/O, no global state. Tested in
/// `TranscriptMarkdownFormatterTests`.
enum TranscriptMarkdownFormatter {

    /// Marker rendered in place of a missing speaker label. Soniox almost
    /// always returns one, but the optional field demands we have a
    /// fallback so the tab does not render "** [00:02]:**" if a buffer
    /// arrives without diarization metadata.
    private static let unknownSpeakerLabel = "Unknown"

    static func format(_ segments: [TranscriptSegment]) -> String {
        segments
            .map { renderSegment($0) }
            .joined(separator: "\n\n")
    }

    /// Clipboard text keeps the attribution and timing without Markdown markers.
    static func plainText(_ segments: [TranscriptSegment]) -> String {
        segments.map { renderSegment($0, markdown: false) }.joined(separator: "\n\n")
    }

    // MARK: - Private

    private static func renderSegment(_ segment: TranscriptSegment, markdown: Bool = true) -> String {
        let speaker = segment.speaker?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? segment.speaker!
            : unknownSpeakerLabel
        let timestamp = "\(formatTimestamp(segment.start))-\(formatTimestamp(segment.end))"
        let label = "\(speaker) [\(timestamp)]:"
        return "\(markdown ? "**" + label + "**" : label) \(segment.text)"
    }

    /// `mm:ss` from a Double seconds value, floored to whole seconds so
    /// a 119.9-second timestamp still reads "01:59" rather than
    /// rounding up to "02:00". Minutes can exceed 99; the formatter
    /// just keeps growing the minutes field rather than overflowing
    /// into hours, which mirrors how Soniox / Otter / Granola display
    /// transcript timestamps.
    private static func formatTimestamp(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        let m = whole / 60
        let s = whole % 60
        return String(format: "%02d:%02d", m, s)
    }
}
