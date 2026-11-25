---
id: subtitle-audio-translate-slot-2026-11-22
type: decision
title: Subtitles run only on OpenAI Audio translate
summary: Subtitles have one engine, OpenAI gpt-realtime-translate, shown as an ordinary API & Models -> Models row with that model preselected, without a switch and without Speech or LLM choices. It runs exactly when the OpenAI key can be read; without one the row looks like any row without a model and Start names the missing key. A session stops itself after one hour, silently, like Stop. The Subtitles Speech and LLM features are retired like Decision, their saved routes ignored but kept, and the per-phrase speech-to-text + LLM path is removed. The owner approved moving existing users' Subtitles audio to OpenAI.
status: confirmed
tags: [translation, subtitles, openai, routing, settings]
canonical_for: [subtitle-audio-translate-slot, subtitles-engine]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22, relayed by the orchestrating session, the user asked why gpt-realtime-translate hid in the Subtitles Speech list and asked for a separate Audio translate slot, filled in because there is one model, lit only with an OpenAI key and used by default with the key.
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: Asked whether users whose Subtitles already ran on Speech and LLM should move to it (about $3 per audio hour to OpenAI instead of their provider), the user said yes, because the users today are the user, their brother and a friend.
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: After seeing renders with dimmed Speech and LLM rows under the slot, the user asked to remove Speech and LLM from Subtitles entirely, to drop the switch (on means the key is there), to make Subtitles unavailable with a clear reason without the key, and to delete the old path's code where nothing else uses it.
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: After renders of a separate Audio translate field with a note under it, the user asked for Subtitles to be an ordinary row with a predefined model, the same as every other row, and without a key in the same state as other rows without a model.
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: The user asked for a session to run at most one hour and then need a new Start, so that nobody is caught out by the bill, and for nothing to show it, no timers and no captions.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleAudioTranslate.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Translation/LiveSubtitleModel.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/AIRouting/AIFeature.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/APIAndModelsView.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleAudioTranslateTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-21-subtitle-speech-translation.md, 2026-11-21-subtitle-phrase-pairs.md, 2026-10-19-api-and-models.md, 2026-10-20-translation-tools.md, 2026-11-21-free-api-report.md, 2026-11-23-subtitle-steady-overlay.md, 2026-11-25-subtitle-soniox-engine.md]
---

# Subtitles run only on OpenAI Audio translate

## Context

The 2026-11-21 build offered OpenAI `gpt-realtime-translate` as one more
model in the Subtitles Speech list, beside a speech-to-text route and a
Subtitles LLM that translated phrase by phrase. The user did not find the
model there, expected a separate filled-in slot, and after seeing it beside
dimmed Speech and LLM rows asked for Speech and LLM to go: the one model
hears and translates, and it is the engine they use.

## Decision

- **An ordinary row.** API & Models -> Models -> Subtitles looks like every
  other feature row: the collapsed line names `gpt-realtime-translate`, and
  the expanded card has one Model menu whose only item is "OpenAI ·
  gpt-realtime-translate". No switch, no Speech or LLM row, no note under it.
- **Runs only with the key.** It runs exactly when the OpenAI key from API
  keys can be read (`SubtitleAudioTranslate.key`). Without one the card has
  the same setup contour as any row without a model, its menu adds "Add an
  OpenAI key…" and the "features have no model" count includes Subtitles.
- **One hour per session.** A session stops itself 60 minutes after it starts
  listening, through the ordinary Stop path (graceful finish, socket closed,
  pairs kept), with no warning, timer or message
  (`LiveSubtitleModel.maxSessionDuration`, a constant without UI). Start
  begins a new hour; Stop, Cancel or a window close cancel the timer.
- **Clear refusal.** Start without the key fails before any system audio is
  captured with "Subtitles need an OpenAI key. Add it in API & Models." and
  the overlay's Open API & Models button, which opens the Subtitles card.
- **Retired features.** `subtitlesAudio` and `subtitlesTranslation` are
  inactive like the Decision route: no rows, no picker, no route resolution.
  Their IDs stay for Costs (Audio translate sessions record under
  `subtitlesAudio`) and history. Saved routes are ignored, not deleted, so a
  rollback build still finds them.
- **Removed.** The speech-to-text + LLM path of `LiveSubtitleModel` (phrase
  queue, three parallel translations, context, deadlines), the phrase
  segmenter's state, `SubtitlePartialLock`, per-phrase LLM prompts
  (`translatePhrase`, `SubtitleContext`) and their tests. The sentence rules
  stay for the pairer. Shared adapter options added for Subtitles (ElevenLabs
  VAD commits, On this Mac live partials) stay in their adapters, unreachable
  from Subtitles.
- **Owner-approved exception.** Users whose Subtitles ran on another
  provider now send their system audio to OpenAI (about $3.06 per audio
  hour) once they have an OpenAI key, and have no Subtitles without one. This
  departs from "never switch where existing users send audio"; the owner
  approved it on 2026-11-22 because the users today are the owner, their
  brother and a friend, all aware.

## Why

- One model with no choice belongs in a filled slot, and showing Speech and
  LLM rows that never run only invites setup that does nothing.
- The translation quality the user wants comes from the model hearing the
  speech (2026-11-21-subtitle-speech-translation.md); the per-phrase LLM
  path cannot match it, so keeping it as a second engine costs code and
  tests for a path nobody uses.
- The same row as the others: a separate field with its own note read as a
  special setting, and the user wanted nothing special to learn.
- Requiring the key and naming it at Start avoids a silent refusal.
- The hour limit protects the users' own money: Audio translate costs about
  $3.06 per audio hour, and a session left running behind a closed lid or a
  forgotten video would keep spending it. A silent stop is enough because
  Start is one click; the user asked for no timer or caption.

## What was tested

- Unit tests: the key states and the missing-key error; Start without the key
  (named issue, opens Subtitles, no capture); retired features (no model use
  on any provider, saved routes ignored and kept across an edit); Costs still
  group Audio translate sessions under Subtitles; the Models card with and
  without the key; the banner count; the hour limit (stops like Stop with no
  message and closes the socket, a new Start begins a new hour, a cancelled
  session's timer does nothing); the adapter, pairer and model tests of
  the Audio translate session (pairs, Stop, drops, errors), and the window
  tests rebuilt on it.
- Offscreen renders: the Subtitles row with and without the key (light and
  dark) and the overlay after Start without the key.
- The remaining subtitle suites passed 15 runs in a row; the flaky failure
  other sessions saw came from the removed path's timing-based tests.
- Not checked in the installed app.

## Rejected

- A separate Audio translate field with "Needs an OpenAI key · Add key" under
  it (built, then replaced by the ordinary row at the user's request).
- A warning before the hour ends or a "stopped after 1 hour" state: the user
  asked for nothing on screen.
- A switch beside the slot with Speech and LLM kept as the Off position (built
  first, then removed at the user's request).
- Recording Off for users whose Subtitles already ran on Speech: the owner
  chose the engine for everyone with a key.
- Deleting the saved Subtitles routes: a rollback build would lose them.
- Removing the ElevenLabs VAD and On this Mac partial options now: they live
  in shared adapters used by Drop and Meetings; left for a separate cleanup.

2026-11-22 · branch claude/subtitles-audio-translate-slot

Update 2026-11-25: the engine is Soniox stt-rt-v6 with the Soniox key, OpenAI
only without it. See 2026-11-25-subtitle-soniox-engine.md.
