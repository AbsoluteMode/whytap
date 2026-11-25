---
id: subtitle-soniox-live-original-2026-11-25
type: decision
title: With Soniox, Subtitles show the original as heard and each translated clause at once
summary: On build 1761 the user found Soniox Subtitles still slow. The installed app did run Soniox; the delay was the overlay holding each original word until its translation arrived (about 2.2 s after the word was heard). Soniox sends its translation only final, a clause at a time, so the original now shows from Soniox's non-final tokens as heard (about 1.1 s), runs on past sentences still waiting for their translation, and each translated clause shows whole at once. Pairs still hold final words only. OpenAI sessions keep the in-step row.
status: confirmed
tags: [translation, subtitles, soniox, latency, overlay]
canonical_for: [subtitle-soniox-live-original]
verified_at: 2026-11-25
sources:
  - type: user-confirmed
    reference: On 2026-11-25, after testing build 1761, the user wrote that the subtitles still take long; the orchestrating session (task 112, REV 3) asked to find from the installed build's logs which engine ran and where the time goes, and to show the translation from Soniox's non-final tokens without waiting for the end of the phrase, measuring before and after on live audio.
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/SonioxRealtimeTranslateAdapter.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleSpeechPairer.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleStreamingPreviewPairerTests.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Tests/SidekeyTests/Translation/SonioxLiveProbeTests.swift
    confirmed_at: 2026-11-25
related: [2026-11-25-subtitle-soniox-engine.md, 2026-11-23-subtitle-pairs-close-speed.md]
---

# With Soniox, Subtitles show the original as heard and each translated clause at once

## Context

The user tested build 1761 (Soniox Subtitles) and found it still slow.

The installed app's log (categories `subtitles` and
`soniox-realtime-translate`, numbers only) shows a 38 s Soniox session that
ended with `finished`. OpenAI did not run. Each translated piece arrived
1.2-1.5 s of audio after the end of the last final original word, with two
outliers at 2.8 and 5.3 s.

A live probe on a 50 s synthetic lecture, sent at real speed, showed what
Soniox `stt-rt-v6` sends:

- The original arrives non-final about 1.1 s after a word is heard, and final
  about 2 s after it.
- Every translated token is final: 0 of about 340 were non-final. Translation
  comes a clause at a time, about 0.75 s after the clause ends, and every
  piece starts at a word boundary.

The overlay showed the live original only as far as its translation had
reached (`liveOriginalAsHeard` false). So each original word appeared about
2.2 s after it was heard, and a sentence's first word about 2.9 s after the
sentence began. A translated piece's last word also waited 0.3-0.55 s
(`wordHold`) in case it was part of a word.

## Decision

These rules apply to a session whose provider streams the original before it
is final (`SpeechTranslationSession.streamsOriginalPreview`, currently Soniox
only):

- **Preview.** Each response's non-final original tokens (`original` and
  `none`, never `translation`, `<end>` or `<fin>`) become one
  `.sourcePreview`. It replaces the previous one; an unchanged preview is not
  sent again, and an empty one clears it.
- **Live row.** The pairer (`init(streamingPreview:)`) shows every final word
  not yet in a pair, followed by the preview. A sentence whose translation is
  late does not hold the next one back. When the pair settles at its cut, the
  words after the cut continue in the next row. This is the as-heard trade
  that the user chose by asking for it.
- **Translation.** Each piece shows whole at once, with no `wordHold`, and a
  broken session keeps its last piece whole.
- **Pairs.** Pairs hold final words only, so a preview never enters one. Cuts,
  pauses and Stop work as before.
- **OpenAI.** OpenAI sessions are unchanged: the original stays in step with
  its translation, and OpenAI's word fragments still wait.

## Why

- The time was lost in the overlay, not in the capture or in sending: in-app
  trail matches the probe within about 0.2 s.
- Soniox does not stream translation earlier than per clause, so the
  original was the only text that could come sooner.

## What was tested

Before and after, two live runs each, on the same 50 s lecture through the
Swift adapter and the real pairer. The screen was sampled at every event and
every 250 ms. A word counts as shown only when it matches the final text
exactly.

| Measure | Before | After |
| --- | --- | --- |
| Original word on screen after it is heard (median) | 2.18 / 2.19 s | 1.08 / 1.16 s |
| Sentence start to its first word on screen (median) | 2.84 / 2.85 s | 1.09 / 1.17 s |
| Sentence end to its whole translation on screen (median) | 0.84 / 0.84 s | 0.75 / 0.87 s |

The remaining ~1.1 s for the original is Soniox's non-final lag, and the
translation is bound to Soniox's clause pace. An earlier after-run kept the
first-sentence-end cap. In it, a translation that Soniox delayed by 4.9 s also
held back the next sentence's original; removing the cap fixed that.

Scenario tests:

- `SonioxRealtimeTranslateAdapterTests`: preview order and replacement, no
  repeat, translation tokens never in it.
- `SubtitleStreamingPreviewPairerTests`: preview after final words, a late
  translation not holding the next sentence, whole pieces, a broken session,
  OpenAI unchanged.
- `SonioxSubtitlesModelTests`: the real model shows the non-final original
  before any translation, a clause whole at once, and pairs of final words.

Not checked: the installed app on real system audio.

## Rejected

- `max_endpoint_delay_ms` 500, with or without
  `endpoint_latency_adjustment_level` 3, measured live: the original's final
  tokens came about 0.5-1 s sooner, but the translation broke into fragments
  (a single sentence came back as six one- or two-word "sentences").
- Manual `finalize` every few seconds: Soniox warns that it lowers accuracy
  and may disconnect, and it is undocumented for translation.
- A dimmer style for the preview tail: possible later if revised words
  distract. Revisions in the probe were small.

2026-11-25 · branch claude/subtitles-soniox-live
