---
id: subtitle-speech-translation-2026-11-21
type: decision
title: Subtitles can run on OpenAI live speech translation
summary: Subtitles audio offers OpenAI gpt-realtime-translate as a route. One WebSocket session hears the system audio and returns the translation and, with input transcription on, the heard original; the Subtitles LLM is not used. The two streams share no segment ids, only the input-audio clock elapsed_ms, so pairs are cut on the translation's sentences and each is matched to the original's sentence that ended before it. Errors are named from status and error codes and end the session visibly.
status: confirmed
tags: [translation, subtitles, openai, routing, costs]
canonical_for: [subtitle-speech-translation, openai-realtime-translate]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21, relayed by the orchestrating session, the user chose an OpenAI gpt-realtime-translate engine for Subtitles on their own OpenAI quota, asked that pairs and Whytap's look stay, and asked whether the model needs a separate speech-to-text model.
    confirmed_at: 2026-11-21
  - type: user-confirmed
    reference: The same day the user chose the band chunk mark ("subtitles-pairs-band.png") over dots and an accent first letter, and set aside ElevenLabs Realtime Translation as a closed test.
    confirmed_at: 2026-11-21
  - type: url
    reference: https://developers.openai.com/api/docs/guides/realtime-translation, https://developers.openai.com/api/docs/models/gpt-realtime-translate, https://developers.openai.com/api/docs/models/gpt-realtime-whisper, https://developers.openai.com/api/docs/pricing and the realtime translation client/server event references (read 2026-11-21) document the wss://api.openai.com/v1/realtime/translations endpoint, session.update with audio.output.language and audio.input.transcription, 24 kHz PCM16 in 200 ms frames, session.close then session.closed, append-only session.input_transcript.delta and session.output_transcript.delta with elapsed_ms in 200 ms steps and no shared segment ids, $0.034 per audio minute for gpt-realtime-translate and $0.017 for gpt-realtime-whisper. No output language list and no session length limit are documented.
    confirmed_at: 2026-11-21
  - type: url
    reference: https://elevenlabs.io/docs/api-reference/realtime-translation/v-1-translation-realtime (read 2026-11-21) says Realtime Translation is for enterprise workspaces only.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/OpenAIRealtimeTranslateAdapter.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleSpeechPairer.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Translation/LiveSubtitleModel.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/AIRouting/AIFeature.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Translation/SpeechTranslationTests.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleSpeechPairerTests.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Translation/OpenAITranslateRecordedSession.swift
    confirmed_at: 2026-11-21
related: [2026-11-21-subtitle-phrase-pairs.md, 2026-10-20-translation-tools.md, 2026-10-19-api-and-models.md, 2026-11-22-subtitle-audio-translate-slot.md, 2026-11-23-subtitle-pairs-close-speed.md, 2026-11-23-subtitle-realtime-audio.md]
---

# Subtitles on OpenAI live speech translation

## Context

Subtitles ran speech-to-text (Soniox, Deepgram, ElevenLabs, a user's server
or this Mac) and translated each phrase with the Subtitles LLM. The user's
standalone RealtimeTranslator, whose translation they found much better,
streams the audio to OpenAI `gpt-realtime-translate` instead: one model hears
and translates continuously. The user asked for that engine in Whytap on
their own OpenAI quota, with Whytap's pairs and look kept.

## Decision

- **A route, not a switch.** Settings -> API & Models offers OpenAI on the
  Subtitles audio row with `gpt-realtime-translate` (a new model use,
  `speechTranslation`, served only by OpenAI and only for Subtitles audio).
  Nothing is changed for anyone: the user picks it. While it is selected,
  the Subtitles LLM row keeps its choice and says it is not used.
  Replaced on 2026-11-22: Subtitles run only on this model, as the single
  Audio translate row with no Speech or LLM choice; see
  2026-11-22-subtitle-audio-translate-slot.md. The rest of this decision
  (session, pairs, errors, costs) is unchanged.
- **One session.** `OpenAIRealtimeTranslateAdapter` opens
  `wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate`
  with the OpenAI key from API & Models, sets the target language and input
  transcription (`gpt-realtime-whisper`), and waits for `session.updated`
  before any audio, so a refused key or language fails at Start. The capture
  is sent at 24 kHz in 200 ms frames (until 2026-11-23 a 16 kHz capture was
  upsampled per callback; see `2026-11-23-subtitle-realtime-audio.md`). Stop flushes the
  rest, sends `session.close` and waits for `session.closed` (the existing
  10 s stop watchdog bounds it). Only `session.closed` is a complete ending:
  a failed `session.close` send, or a socket lost before `session.closed`,
  is a lost connection, because the last translation may be missing (found
  by the integration builder's review). Only the app's own teardown ends
  quietly. On any failure the translation already received becomes pairs,
  without a half-said last word, before the error shows.
- **No separate speech model.** The heard original comes from the same
  session's input transcript. A translation without an original still shows
  (right column only).
- **Pairs.** `SubtitleSpeechPairer` cuts the translation at a sentence end
  (at once when more text follows, after 0.3 s when it ends the stream), at
  a 1.2 s pause, or at a clause past 160 characters. Each cut takes the
  original's next sentence if that sentence ended (by `elapsed_ms`) no later
  than the translation; sentences that ended 5 s or more earlier join it (the
  model merged them). Since 2026-11-23 a later sentence heard by the cut
  joins too when the translation's length and delay fit it better
  (2026-11-23-subtitle-pairs-close-speed.md). Without a finished original sentence (a pause, whose
  period arrives with the next word, or a sentence the model split) it takes
  the words heard up to the translation's position, whole words only. A
  period arriving after its pair closed is added to that pair.
- **Live pair.** The sentence being heard shows its original (the newest
  ~90 characters) beside the translation still being spoken, dimmed and in
  whole words only (the model streams parts of words).
- **Errors.** Status and error codes only, never provider text: a refused
  key (401/403, authentication codes), no credit (402, insufficient_quota and
  similar), busy (429, rate limits), an unsupported target language (error
  param naming the output language), a dropped socket or a socket that ends
  without `session.closed`. Each ends the session with a message naming the
  cause; key and credit messages open API & Models on Subtitles audio.
  Finished pairs stay. Unknown, recoverable error events are logged by type
  and ignored.
- **Costs.** One estimated row per session from the audio OpenAI accepted:
  $0.034 + $0.017 per minute, **$3.06 per hour of audio**.

## Why

- The quality the user wanted comes from the model hearing the speech, not
  from a better prompt: the per-phrase LLM path cannot match it.
- One session halves the hops: the original appears about 0.4 s after it is
  said and its translation 0.4-3 s of audio later (measured below), with no
  per-phrase request.
- Sentence alignment uses only what the API guarantees (ordered deltas and
  the input clock). On the recorded session the two streams keep sentence
  for sentence, and every translation ends before the next original does.

## What was tested

- `GET /v1/models` with the user's OpenAI key (2026-11-21): only
  `gpt-realtime-translate` (created 2026-05-05); no dated snapshot or
  successor. `gpt-realtime-whisper` is listed.
- A live session (37.7 s of synthetic English speech, about $0.03): Russian
  output works, the input transcript arrives as whole words with the
  previous sentence's period leading the next word, both streams carry
  `elapsed_ms`. The recording is the test fixture; replayed through the
  pairer it gives all 8 sentence pairs exactly, each closing at most 0.5 s
  after its translation ends.
- Session opens without audio (free): 55 of the 56 target languages in
  Whytap's menu are accepted; Punjabi (`pa`) is refused with
  `invalid_value` on `session.audio.output.language`, shown as "does not
  support Punjabi".
- A wrong key: the handshake is refused (401), reported as a refused key in
  0.8 s.
- Unit tests: the adapter on a stub socket (session.update shape, framing,
  close flush, 401, insufficient_quota, unsupported language, a recoverable
  error, a dropped socket, a start timeout); the model with a fake session
  (pairs and Stop, a dropped socket, a socket ending without close, refused
  key before audio, credit, language, a provider that never closes); the
  pairer (merged and split sentences, pause and late period, empty streams,
  a long translation).

## Rejected

- Using the existing speech-to-text route for the original beside OpenAI's
  translation: two paid streams for one column, aligned only by time.
- Translation-only rows: the user asked to keep pairs, and the model gives
  the original for $0.017 a minute more.
- Pairing by sentence count alone: one merged or split sentence would shift
  every later pair; the clock keeps them in step.
- ElevenLabs Realtime Translation as a second engine: its documentation says
  enterprise workspaces only, and a free check on 2026-11-21 got HTTP 403 for
  the user's key and for an invalid key alike, while the same key opened
  speech-to-text. Worth adding when it is generally available.
- Reconnecting a dropped session automatically: it would hide a lost
  stretch of speech; the session ends visibly instead. OpenAI documents no
  session length limit, so a long video may need a restart; unmeasured.

2026-11-21 · branch claude/subtitles-chunks-4cbe08
