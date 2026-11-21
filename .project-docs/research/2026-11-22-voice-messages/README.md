# Voice messages from messengers without built-in transcription

Research only, paused by the maintainer on 2026-11-22. No feature code was written.
Base: `origin/main` f32c4029. The annotated renders are in Russian for the maintainer.

## Problem

Some messengers (for example eXpress) have no transcription of voice messages.
The maintainer wants the text of a voice message without listening to it, in any
messenger.

## Round 1: capture while the message plays (`v1/`)

- A: a Listen hotkey arms capture; the first app that starts playing is captured;
  live text in the island, the full text in a card at the end.
- B: Whytap offers to transcribe when a messenger starts playing audio.
- C: one session for a series of messages, one block per message, Copy all.

Feasibility from the code:
- `CoreAudioSystemAudioSource` uses a global process tap that excludes Whytap.
  Meetings and Subtitles use it with the System Audio Recording permission.
- `CATapDescription(monoMixdownOfProcesses:)` captures selected processes with the
  same permission, so ScreenCaptureKit is not needed.
- `AudioProcessProbe` already lists audio processes. Adding
  `kAudioProcessPropertyIsRunningOutput` would tell which app is playing.
- Chromium and Electron apps play audio from a helper process. That process must
  be mapped back to its app.

The maintainer rejected listening, so round 2 replaced this approach.

## Round 2: without listening (`v2/`)

### Decoding

These checks ran on macOS 27.2 with `AVAudioFile` and `afconvert` on generated files:

| Format | Typical source | Decoded by the system |
|---|---|---|
| Opus in Ogg (.ogg, .oga, .opus) | Telegram, WhatsApp, Discord | yes |
| .m4a, .mp3, .wav, .caf | phones, clips | yes |
| Opus in WebM (.webm) | browser recordings | no |

Whytap supports macOS 14.2 and later. Ogg decoding on macOS 14 and 15 was not checked.

One pipeline would serve every file variant: file → `AVAudioFile` → 16 kHz mono
PCM16 → `BatchTranscribing` (`ProviderBatchTranscriber` or
`OnDeviceBatchTranscriber`). It would add one new batch route in API & Models,
because invariant 3 forbids borrowing another feature's route.

The Soniox batch poll stops after 30 s. Longer files need their own deadline, or
`RecordedMeetingTranscriber` from Meetings.

### Variants

1. **Downloads folder.** The user saves a voice message in the messenger and
   Whytap transcribes the new audio file. The default mode is Ask first.
   Automatic mode handles only short, mono, low-bitrate files, which keeps music
   out. The setting is off by default.
   - The Downloads folder is protected, so macOS asks for access once. A folder
     the user picks in a file dialog needs no prompt.
2. **Drop onto the island, Finder Quick Action.** These are manual entries into
   the same pipeline. The Quick Action is a macOS Service declared in Info.plist.
   - I found no documentation that the messengers let a voice message be dragged
     out directly.
3. **Silent capture (fallback).** A tap on the messenger's process uses
   `muteBehavior = .muted`, with playback at 2×.
   - Apple documents `.muted` as captured audio that is not sent to the output
     device. This was not verified by hand.

### Price per minute (batch)

| Provider | Price per minute |
|---|---|
| Soniox async | about $0.0017 ($0.10 per hour) |
| Deepgram nova-3 pre-recorded | $0.0043 |
| ElevenLabs Scribe v3 | about $0.004 to $0.007 (sources disagree) |
| On this Mac | free |

## Recommendation

Build one file pipeline with three entry points: the Downloads folder in Ask
first mode, a drop onto the island and the Finder Quick Action. The size is
medium, about three to four days.

Add silent capture only if eXpress cannot save voice messages. The open question
for the maintainer is whether eXpress for Mac offers Save or Download on a voice
message.

## Risks

- Privacy: Whytap reads new files in the watched folder and accepts only those
  that look like voice messages. Audio reaches a provider only from files the
  user downloaded. On this Mac keeps everything local.
- Cost: automatic mode could transcribe unwanted files. The length and mono
  filters limit that, and the amounts are small.
- Technical: WebM is not decoded by the system. Ogg on macOS 14 and 15 is
  unverified. The Soniox batch deadline is short.

## Files

- `v1/`, `v2/`: annotated renders, one sheet per variant.
- `src/`: the mockup generators (`build.mjs`, `build2.mjs`, `mock.css`).
  - They write to the orchestrator folder on the maintainer's Mac.
  - They need Playwright with a local Chromium.
