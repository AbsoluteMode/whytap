---
id: subtitle-soniox-engine-2026-11-25
type: decision
title: Subtitles run on Soniox live translation, OpenAI only without a Soniox key
summary: Subtitles stream system audio to Soniox stt-rt-v6 one-way translation with the Soniox key Drop already uses; the original and its translation arrive in one WebSocket and pair as before. Without a readable Soniox key Subtitles fall back to OpenAI gpt-realtime-translate with the OpenAI key; without either Start names the missing key. There is no engine choice in Keys & models. A sentence's translation arrives about 0.5-1 s after it ends instead of 3.6-4 s, at about $0.12 per audio hour instead of $3.06.
status: confirmed
tags: [translation, subtitles, soniox, openai, latency, routing]
canonical_for: [subtitles-engine, subtitle-soniox-engine]
verified_at: 2026-11-25
sources:
  - type: user-confirmed
    reference: On 2026-11-25, shown the live measurement (OpenAI 3.6-4 s, Soniox about 0.8 s from the end of a sentence to its translation), the user answered "а нихуя себе нука включи мне", then "давай заменим я потестирую", relayed by the orchestrating session (task 112, REV 2) as replace the Subtitles engine with Soniox, keep OpenAI only as the fallback without a Soniox key, no engine choice in Keys & models.
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/SonioxRealtimeTranslateAdapter.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleAudioTranslate.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Tests/SidekeyTests/Translation/SonioxRealtimeTranslateAdapterTests.swift
    confirmed_at: 2026-11-25
related: [2026-11-22-subtitle-audio-translate-slot.md, 2026-11-21-subtitle-speech-translation.md, 2026-11-23-subtitle-pairs-close-speed.md, 2026-11-25-subtitle-overlay-move-resize-scroll.md]
---

# Subtitles run on Soniox live translation, OpenAI only without a Soniox key

## Context

Subtitles ran on one OpenAI `gpt-realtime-translate` session
(2026-11-22-subtitle-audio-translate-slot.md). Measured live on 2026-11-25
(2026-11-25-subtitle-overlay-move-resize-scroll.md, same 48 s lecture, two
runs each): a sentence's translation was complete 3.6-4 s after the sentence
ended with OpenAI, about 0.8 s with Soniox `stt-rt-v6` one-way translation.
OpenAI's API has no latency setting. The user asked to switch.

## Decision

- **Engine.** `SubtitleAudioTranslate.engine(soniox:openAI:)`: Soniox
  whenever the Soniox key (the `BYOKKeyStore` account Drop uses) can be read;
  otherwise OpenAI with its key; otherwise Start names the missing key ("a
  Soniox or OpenAI key") and captures nothing. An unreadable key is named only
  when no other key works.
- **Adapter.** `SonioxRealtimeTranslateAdapter` opens
  `wss://stt-rt.soniox.com/transcribe-websocket` with the key in the
  `Authorization` header and sends the config: `stt-rt-v6`, 24 kHz PCM16 mono
  (the Subtitles capture, unchanged), endpoint detection, `language_hints`
  with the chosen source (none for Detect), `translation: one_way` to the
  target. Start waits for Soniox's first answer (it comes without audio), so a
  refused key or unsupported language fails before capture. Audio goes in
  100 ms binary frames; Stop sends the rest and an empty text frame, and only
  `finished` is a clean end.
- **One stream, the same pairs.** Only final tokens are passed on, as the
  append-only deltas `SpeechTranslationSession` promises; `<end>` and `<fin>`
  are dropped. An original token carries its `end_ms`; a translated token has
  no timestamp and takes the end of the last final original token, the audio
  it translates. `SubtitleSpeechPairer` pairs them unchanged. Tokens marked
  `none` (already in the target language) are both original and subtitle.
- **Errors.** Soniox `error_code`s are HTTP statuses: 401/403 refused key,
  402 no credit, 429 busy, 400 at start the language, 408 lost connection,
  others the provider. A socket lost mid-session or after the end of audio is
  a lost connection; pairs on screen stay. Messages name the engine in use
  ("Soniox refused the API key…").
- **Settings.** Keys & models -> Models -> Subtitles stays one ordinary row
  with a preselected model: "Soniox · stt-rt-v6" with a Soniox key,
  "OpenAI · gpt-realtime-translate" with only an OpenAI key. No engine menu.
  Costs record each session under the engine's account and model.

## Why

- Speed is what the user asked for: about five times faster to a finished
  translation, at about a twentieth of the price.
- The user already has the Soniox key for Drop; no new setup.
- OpenAI stays only so that someone with just an OpenAI key keeps working
  Subtitles. A choice in Keys & models was offered and cancelled (REV 2).
- Pairing on final tokens keeps the overlay's promise that shown text never
  moves: Soniox's non-final tokens are revised and would make words jump.

## What was tested

`SonioxRealtimeTranslateAdapterTests` over a stub socket:

- the config (model, 24 kHz, endpoint detection, hints, one-way target, no
  key in the frame);
- the original and its translation in one stream: non-final tokens and
  `<end>` ignored, translations placed at their original's end; `none`
  tokens are their own translation;
- 4,800-byte binary frames, the rest and an empty text frame at Stop,
  nothing after it;
- refused key (error frame and refused handshake), unsupported language,
  credit, busy, provider; no answer at start times out;
- a dropped socket mid-session and after the end of audio, a failed end of
  audio, an error mid-session: all fail named; the app's own close is quiet.

`SonioxSubtitlesModelTests`: the real Subtitles model on a Soniox session
forms the two pairs and stops on `finished`; a broken socket keeps the pairs
and shows the connection message; a refused Soniox key names Soniox and never
captures audio. `SubtitleAudioTranslateTests`: Soniox key -> Soniox, only
OpenAI -> OpenAI, neither -> missing key, unreadable -> named; the Models row.

Live (`SonioxLiveProbeTests`, skipped by default; run through Case with the
dev key): the 48 s lecture at real speed through the Swift adapter and the
pairer gave 21 correctly matched pairs (clause by clause, as Soniox finalizes
at pauses), `finished` at the end, each sentence's translation 0.3-1.1 s
after the sentence ended. Not checked: the installed app on real system
audio; the user tests that on the installed build.

## Rejected

- An engine choice in Keys & models (Soniox / OpenAI): cancelled by the user.
- Showing Soniox's non-final tokens: faster by a few hundred ms, but shown
  words would change and move.
- The config frame's `api_key`: Soniox deprecates it; the header works.

2026-11-25 · branch claude/subtitles-soniox-engine
