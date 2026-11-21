---
id: subtitle-phrase-pairs-2026-11-21
type: decision
title: Subtitles show phrase pairs and translate whole phrases sooner
summary: The subtitle box keeps Whytap's compact style and shows each phrase as a pair, original on the left and translation on the right. Each phrase is translated with the speech around it as context, the closest a per-phrase request gets to the continuous view of a one-hop speech translator. Speech is cut into whole phrases, never inside a word, and up to three phrases translate at once. ElevenLabs Subtitles commit at pauses and translate the stable start of the partial instead of waiting for Scribe's ~36 s segment cap, which is what made subtitles slow and cut words in half.
status: confirmed
tags: [translation, subtitles, elevenlabs, latency, design]
canonical_for: [subtitle-phrase-pairs, subtitle-phrase-segmentation, subtitle-elevenlabs-commit]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user watched an English lecture with Subtitles EN to RU and reported that the overlay was slow and showed one running Russian text with words cut in half (a Russian verb broken off with a hyphen, its object starting the next piece). They asked for faster subtitles and for chunks matched as source language on one side and target language on the other, pointing at their standalone RealtimeTranslator.
    confirmed_at: 2026-11-21
  - type: user-confirmed
    reference: The standalone RealtimeTranslator (a local example project outside this repository, last commit 6938a3e, and its installed build) was read on 2026-11-21. It streams system audio to one OpenAI gpt-realtime-translate WebSocket and shows only the translated text as one running caption, throttled to about 14 updates a second. It has no source/translation pairs.
    confirmed_at: 2026-11-21
  - type: user-confirmed
    reference: Later on 2026-11-21, relayed by the orchestrating session, the user said they like Whytap's subtitle interface even more than the standalone app's, but the standalone app's translation quality is much better. Keep Whytap's look; bring over the quality.
    confirmed_at: 2026-11-21
  - type: url
    reference: https://developers.openai.com/api/docs/guides/realtime-translation, https://developers.openai.com/api/docs/models/gpt-realtime-translate and the realtime translation client/server event references (read 2026-11-21) document 24 kHz PCM16 input in 200 ms frames, append-only session.output_transcript.delta and, only with input transcription configured, session.input_transcript.delta, alignment by elapsed_ms without segment ids, no prompt, glossary or turn settings, a 16,000-token context window and a price of $0.034 per audio minute.
    confirmed_at: 2026-11-21
  - type: url
    reference: https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies and https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime (read 2026-11-21) document commit_strategy manual or vad, vad_silence_threshold_secs from 0.192 to 3.0 s, committed_transcript messages and the automatic commit after about 36 s of audio under manual commit.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleSegmenter.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitlePartialLock.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Translation/LiveSubtitleModel.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleCaption.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitlePairLayouts.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/ElevenLabsBYOKAdapter.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitlePhrasePairTests.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleLatencyBenchmarkTests.swift
    confirmed_at: 2026-11-21
related: [2026-11-21-compact-subtitle-overlay.md, 2026-10-20-translation-tools.md, 2026-11-12-drop-auto-stop-local-rule-only.md]
---

# Subtitle phrase pairs

## Context

The user's Subtitles route is ElevenLabs `scribe_v3_live` for speech and a
language model through OpenRouter for translation. Watching an English
lecture, they saw one running Russian paragraph that arrived late and in
pieces, with words cut in half. They asked for two things: faster subtitles,
and chunks shown as pairs, original on one side and translation on the
other, so it is clear which part became which. They pointed at their earlier
standalone RealtimeTranslator as the reference.

What the reference actually did: it sent system audio to one OpenAI
`gpt-realtime-translate` socket and drew the translated text as a single
running caption. It was fast because there was one streaming hop from audio
to translated text, not because of how it cut speech; it showed no pairs and
no original. Whytap's Subtitles are a speech-to-text route followed by a
separate LLM route (the user chooses both, BYOK), so the speed has to come
from the pipeline, and the pairs are a new presentation.

Where the time went:

1. ElevenLabs sessions use `commit_strategy=manual`, which is right for a
   dictation take that ends with our commit. Subtitles never end a take, so
   Scribe only committed when its own ~36 s segment cap was reached. Every
   word waited up to half a minute, and the cap fell inside a word: the
   two halves were translated in different requests, which the model
   rendered as a word broken off with a hyphen and an ellipsis. A recorded
   ElevenLabs session in the repository shows the same: its first commit
   arrives at 35.6 s.
2. The old segmenter released text on a two-second budget at any character,
   so Soniox subword finals were also cut inside words ("who has sp" /
   "ent ten years").
3. Translations ran strictly one after another, so one slow answer held
   every later phrase.

## Decision

- **Pairs.** The box shows the newest phrases as pairs: the original in a
  narrower left column (40 %, smaller, dimmed) and the translation in the
  wider right column, aligned on their first baselines. Russian runs longer
  than English and is the line being read. Pairs are bottom-anchored and only
  whole pairs show (`NewestRowsLayout`), so an old pair leaves at the top in
  one piece; a new pair fades and slides in from the bottom (none with Reduce
  Motion). The phrase still being heard is the last row, original only,
  dimmer, with a pending mark. A pair waiting for its translation shows the
  mark; a failed one shows "Not translated" next to its original. The
  Toolbox pane is too narrow for two columns and stacks the original above
  the translation. The compact overlay, its size, the hover controls and the
  status lines are unchanged.
- **Whole phrases.** `SubtitleSegmenter` cuts committed text at a sentence end
  inside the text at once, at a sentence end at the tail after 0.15 s, at a
  0.6 s pause in finals, and, for a phrase of 60 characters or 2.5 s without
  punctuation, after its last clause mark or else before its last word and
  any function words before it ("every weight | a little bit"). It never
  cuts inside a word. Abbreviations, initials and decimals do not end a
  sentence. Phrases with no letter or digit are dropped. 300 characters is
  the hard limit per request.
- **ElevenLabs commits at pauses for Subtitles only.** The adapter takes a
  commit strategy; the factory gives `vad` with a 0.5 s silence threshold to
  `subtitlesAudio` and `manual` to every take-based feature (Drop, Agent
  voice, Voice search, Meetings), whose rules are unchanged. Ending a VAD
  session sends 0.7 s of silence before the commit, because the docs do not
  say whether a manual commit is honoured under VAD.
- **Stable partials for ElevenLabs.** Its `partial_transcript` is the whole
  segment so far (`partialsSpanSegment`). `SubtitlePartialLock` cuts phrases
  from its start once the words have been unchanged for 0.6 s, never the last
  word and never a word ElevenLabs still marks unfinished with a trailing
  hyphen (a Russian word cut after two letters, "vy-"), by the same boundaries as committed text. When the provider
  revises words it already sent (it removes fillers and repeats), the lock
  realigns by words. At the commit, the words already cut are removed from
  the committed text by word alignment (exact prefix, then the last one to
  three words, then the words before a corrected or removed last word), so
  each spoken word lands in one pair. Committed text always goes before newer
  partial text.
- **Parallel translation with the speech around it.** Up to three phrases are
  translated at once. Each request carries up to three finished pairs
  (900 characters) as earlier user/assistant turns and up to two phrases said
  since, whose translations are still on their way, quoted in the system
  message as context not to translate. The subtitle prompt describes
  continuous speech: keep terms, names, pronouns and grammatical gender, let
  a phrase that starts mid-sentence read as a continuation, return a complete
  phrase without hyphens or ellipses and never repeat earlier text. A late
  answer only fills its own pair; a cancelled session ignores it.
- **Failures stay local.** Each phrase has an 8 s deadline. A timeout, a busy
  or failing provider or an empty answer marks only that pair; subtitles go
  on. Missing setup, a refused key (401/403), no credit (402) or a missing
  model (404) stop the session with the existing actionable message, as
  before. Nine untranslated phrases still stop it visibly instead of falling
  behind.
- The flush timer runs every 100 ms (was 250 ms) and releases every ready
  phrase, not one per tick. No route, model or provider is changed.

## RealtimeTranslator compared

The user likes Whytap's interface more and finds the standalone app's
translation quality much better. Item by item:

| | RealtimeTranslator | Whytap before | Whytap now |
|---|---|---|---|
| Model | One speech-to-translation model, OpenAI `gpt-realtime-translate`: it hears the audio itself. | Speech route (ElevenLabs `scribe_v3_live`), then a separate LLM route (Claude Sonnet 5.5 via OpenRouter). | Same routes; no model changed. |
| Cutting speech | None on the client: 24 kHz audio streams continuously and the model decides where translation flows. | Provider commit (ElevenLabs: ~36 s cap, mid-word), then a 2 s budget at any character. | VAD commit at 0.5 s pauses, stable partial start, whole phrases at sentence, clause or word boundaries. |
| Context | The model's own 16,000-token window over the continuous stream: every word is translated knowing what came before. | Each chunk alone, no context. | Up to three finished pairs and the phrases in flight around each phrase. |
| Prompt and parameters | No prompt, no glossary, no turn settings: only the output language (`ru`). | Generic text-translation prompt, lowest reasoning, throughput-sorted provider. | Live-subtitle prompt for continuous speech; same reasoning and provider settings. |
| Partial and final results | Append-only translated deltas, never revised; only translated text shown (about 14 updates a second). | Partials ignored; finals only, translated chunk by chunk. | Finals and stable partials become phrases; the live original shows from partials; translations never rewrite. |

What gives the standalone app its quality is the model, not a setting: one
model hears the speech and translates it in one continuous context, so
there is no recognition error to inherit, no chunk boundary to translate
across and no lost antecedent. Whytap's two-hop route can only approach this
with whole phrases and the surrounding context, which is what this change
does. The same model is available to Whytap users with an OpenAI key as a
separate Subtitles engine; it is a product choice for the user (its price is
$0.034 per audio minute, about $2 per hour of video), and pairs would rest on
approximate `elapsed_ms` alignment of a separately billed source transcript,
so it is proposed, not built here.

## Why

- Pairs answer the request directly: which original became which
  translation is visible at a glance, and the original appears about 0.3 s
  after it is spoken, before its translation.
- The ElevenLabs manual commit was the dominant delay and the source of the
  cut words; a pause-based commit plus the stable partial removes both
  without changing the provider or model the user chose.
- Cutting at word and phrase boundaries removes the fragments for every
  provider; parallel requests keep one slow answer from delaying the rest.
- Short phrases translate worse in isolation; the surrounding pairs and the
  phrases in flight give each request most of what a continuous translator
  sees, without asking the model to translate any of it again.

## What was tested

- Deterministic latency model (`SubtitleLatencyBenchmarkTests`, one scripted
  142-word, 58.6 s lecture, same assumed provider and model delays for both
  pipelines). Word spoken to its translation on screen, median / p90:
  - ElevenLabs, assumed Claude Sonnet 5.5 via OpenRouter: 18.08 / 33.05 s
    before, 3.36 / 4.21 s after; mid-word cuts 1 to 0.
  - ElevenLabs, assumed fast model: 16.14 / 31.09 s before, 2.62 / 3.47 s
    after.
  - Soniox, assumed Sonnet 5.5: 3.47 / 4.87 s before, 3.73 / 4.62 s after;
    mid-word cuts 6 to 0. Soniox finals were already continuous, so whole
    phrases cost about 0.25 s in the median and gain in the tail; the
    original now shows after about 0.25 s.
- Replay of a real recorded ElevenLabs session (95 words, 44.3 s, with
  revised punctuation and removed fillers): the first phrase is cut at 1.7 s
  instead of the first commit at 35.6 s; a heard phrase goes to translation
  after a median 0.83 s (max 1.83 s) instead of 16.17 s (max 34.58 s); one
  word differs between the pairs and the commit.
- Scenario tests: phrase cutting of continuous subword finals, long phrases
  without punctuation, abbreviations; revised partials never change a
  committed pair; three phrases in flight and answers out of order fill only
  their own pairs; phrases in flight see the phrases said before them, and a
  later phrase gets the three finished pairs as context; empty and
  punctuation-only recognition make no pairs and no requests; a timed-out
  and a failed phrase keep their originals while later phrases translate; a
  refused key stops the session; Stop waits for every phrase in flight; the
  ElevenLabs URL and factory choose VAD only for Subtitles; a VAD session
  ends with silence and the commit; the partial lock's cuts, revisions and
  commit alignment.
- Offscreen @2x renders of the overlay with four pairs, with a pending pair
  and the live original, stopped with the controls row, and the Toolbox
  pane. They do not prove live provider timing, native hover or real
  translation quality.

## Rejected

- Switching Subtitles to OpenAI `gpt-realtime-translate` in this change: it
  is the source of the reference's quality and speed, but it would replace
  the user's chosen speech and LLM routes, and its original text for pairs
  is a separate transcription aligned only by elapsed time. Proposed to the
  user as an opt-in Subtitles engine instead.
- A larger context (whole session history): more tokens on every request for
  little gain once the neighbouring phrases are present.
- Translating every partial: paid requests for text that is still changing,
  and pairs that would rewrite themselves.
- ElevenLabs `turn_prediction`: available only for `scribe_v3_live`, and turn
  prediction already cut Drop takes in the wrong place.
- A VAD threshold below 0.5 s: with the stable partial it barely changes
  latency and commits more often, which the provider says can hurt accuracy.
- Two equal columns: Russian wrapped onto a second line while the original
  column stayed half empty. Clipping pairs by height: it left a translation
  line on screen without its original.

2026-11-21 · branch claude/subtitles-chunks-4cbe08
