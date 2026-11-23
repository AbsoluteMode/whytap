---
id: subtitle-realtime-audio-2026-11-23
type: decision
title: Subtitles send the translation model clean 24 kHz audio; the rest of the delay is the model's
summary: Subtitles captured the system mix at 16 kHz with a linear resampler and no low-pass, then upsampled each callback to 24 kHz. Sound above 8 kHz folded into the speech band at full level, each callback left a seam, and 0.13 % of the audio was lost. Subtitles now capture at 24 kHz through a windowed-sinc low-pass and send it unchanged; Meeting Notes keep their 16 kHz path. Kept in sync with its original, the translation trails the speaker by what the model needs, 0.2 to 3 s per sentence, and our display adds at most about 0.4 s. A live probe compares the old and new audio and the original's transcript on and off once a key is available.
status: confirmed
tags: [translation, subtitles, audio, latency]
canonical_for: [subtitle-realtime-audio]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: The user declined showing the original before its translation and asked that both columns stay in sync and in real time, asking why a model named realtime translate trails by seconds; relayed by the orchestrating session on 2026-11-23.
    confirmed_at: 2026-11-23
  - type: url
    reference: https://developers.openai.com/api/docs/guides/realtime-translation and https://developers.openai.com/api/docs/models/gpt-realtime-translate (read 2026-11-23) document 24 kHz PCM16 mono input, that lower-quality audio materially degrades translation quality, 200 ms engine frames with shorter chunks buffered until a frame is full, appending silence while the session is active, and session.update fields audio.output.language, audio.input.transcription and audio.input.noise_reduction only. No latency, turn detection or mode setting and no typical delay figure are documented.
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Meetings/CoreAudioSystemAudioSource.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/OpenAIRealtimeTranslateAdapter.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Translation/LiveSubtitleModel.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleCaptureAudioTests.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Translation/SpeechTranslationLiveProbeTests.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Translation/OpenAITranslateRecordedSession.swift
    confirmed_at: 2026-11-23
related: [2026-11-23-subtitle-pairs-close-speed.md, 2026-11-21-subtitle-speech-translation.md]
---

# Subtitles send the translation model clean 24 kHz audio; the rest of the delay is the model's

## Context

The user declined showing the original before its translation: both columns
must stay in sync and in real time. The question was why
`gpt-realtime-translate` trails the speaker by seconds in Whytap, and how
much of that is ours.

## Decision

- Subtitles capture the system mix at 24 kHz (`LiveSubtitleModel.captureSampleRate`).
  `SystemAudioAntiAliasFilter` low-passes it before the resampler. The
  filter is a 65-tap Blackman windowed sinc from 48 to 24 kHz, cut off at
  0.42 of the target rate, and keeps its history across callbacks.
- `OpenAIRealtimeTranslateSession.sendAudio` sends that PCM unchanged in
  200 ms frames. The per-callback 16-to-24 kHz upsampling is gone.
- Meeting Notes keep their 16 kHz capture: `CoreAudioSystemAudioSource()`
  without arguments is unchanged.
- The original stays in step with its translation, as the user chose.
  `SubtitleSpeechPairer.liveOriginalAsHeard` stays false.

## Why

The model's input was damaged. Measured with the capture path's own code on
48 kHz tones, in 512-frame callbacks:

| Path | 1 kHz tone: everything else | 12 kHz tone, folded to 4 kHz | Audio kept |
|---|---|---|---|
| Before: 16 kHz, no low-pass, upsampled per callback | -27 dB | -1 dB | 99.87 % (87 ms lost in 67 s) |
| Now: low-pass, 24 kHz | -88 dB | below -250 dB | 100 % |

- **Folding.** The linear resampler with step 3 keeps every third sample.
  Everything between 8 and 24 kHz (music, sibilants, a second voice's
  overtones) came back inside the speech band at nearly full level.
- **Seams.** The upsampler restarted at every callback, about every 10 ms.
  It held the last sample and truncated half a sample about every third
  callback, the defect `docs/bugs/2026-10-07-system-audio-resampler-phase.md` fixed for
  Meeting Notes.
- **Clock.** The model's `elapsed_ms` therefore ran 0.13 % behind the video
  (0.8 s per 10 minutes).

OpenAI states that lower-quality audio materially degrades translation
quality. RealtimeTranslator, which the user calls real time, captures 24 kHz
directly with a high-quality converter.

## Where the delay is

From the recorded live session (`OpenAITranslateRecordedSession`, 37.7 s,
2026-11-21) and the code:

- **The model.** Both streams arrive at the same distance behind their
  `elapsed_ms`: medians 2.7, 3.4 and 3.9 s for the source and 2.5, 3.4 and
  3.9 s for the translation, by thirds. That figure includes the recording's
  start-up and its slow pacing. Neither stream waits for the other.
- **The translation behind its original.** A sentence's translation ends
  behind the original's period by 0.2, 1.5, 1.5, 3.0, 3.0, 2.3 and 3.0 s of
  wall time, sentence by sentence. It starts almost at once and settles near
  3 s after about 20 s, which matches the user's "at once, then behind". The
  model holds that lookahead to translate whole phrases. Nothing in the
  session config changes it: the docs list no latency, turn or mode setting.
- **Ours.**
  - The 200 ms frame: the server buffers to its 200 ms frames anyway, so
    nothing is added.
  - A held last word: at most 0.3 s.
  - Caption publishing: at most 80 ms.
  - The original in step: its words show when the translation's delta at
    the same audio position arrives, within one 200 ms step. The next
    sentence's original waits for its pair, which is the sync the user
    chose.

  Together that is at most about 0.4 s, and it does not grow (the 180 s
  display replay in `2026-11-23-subtitle-pairs-close-speed.md`).

## Not measured yet

The OpenAI key is not available to this session through Case. Whether
clean audio shortens the model's lookahead, and whether the original's
transcript (`gpt-realtime-whisper`) costs the translation time, needs live
runs. `SpeechTranslationLiveProbeTests` now sends a 48 kHz file through the
old path (`WHYTAP_TRANSLATE_PROBE_PATH=old`) or the new one, with the
transcript on or off (`WHYTAP_TRANSLATE_PROBE_TRANSCRIPTION=0`), at real
speed in 512-frame callbacks. Comparing the sentence lags of the runs
answers both.

## What was tested

- `SubtitleCaptureAudioTests`:
  - a 14 kHz tone does not fold to 10 kHz (below -40 dB; without the
    filter, above -3 dB);
  - a 1 kHz tone passes clean across callbacks (error below -50 dB);
  - callback sizes of 512 and 333 give the same audio and exactly half the
    samples;
  - capture at or below 24 kHz passes unchanged.
- `SpeechTranslationModelTests` / adapter test: 24 kHz bytes go out
  unchanged in 200 ms frames, and the rest is flushed at close.
- `CoreAudioSystemAudioSourceTests` and `SubtitleAudioDrainTests` still pass
  on the Meeting Notes path.

## Rejected

- **Sending each callback without 200 ms frames, as RealtimeTranslator
  does.** OpenAI buffers shorter chunks to 200 ms, so it saves nothing.
- **Showing every delta at once.** It saves at most the 0.3 s word hold.
  Half words would show, and words growing past the line end would jump
  lines (`2026-11-23-subtitle-pairs-close-speed.md`).
- **Showing the original as heard.** The user declined it.
- **Noise reduction.** The capture is the clean digital mix. The docs list
  it as optional and do not tie it to latency.
- **Switching Meeting Notes to 24 kHz.** Their speech models take 16 kHz,
  and this change does not touch them.
