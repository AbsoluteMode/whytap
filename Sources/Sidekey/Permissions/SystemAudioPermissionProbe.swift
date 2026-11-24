import Foundation

/// Makes macOS ask for system audio (System Audio Recording Only) when the
/// person asks for it, instead of at their first meeting or subtitles: a
/// moment of the same process tap Meetings and Subtitles use. Nothing reads
/// its buffers; the audio is dropped. macOS asks once and offers no status
/// check, so the caller cannot know the answer.
// WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
enum SystemAudioPermissionProbe {
    static func ask(holding seconds: TimeInterval = 1) async {
        let source = CoreAudioSystemAudioSource()
        do { try await source.start() } catch { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await source.stop()
    }
}
