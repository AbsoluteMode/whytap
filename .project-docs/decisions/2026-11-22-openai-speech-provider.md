---
id: openai-speech-provider-2026-11-22
type: decision
title: OpenAI is a speech provider again, on the shared OpenAI key and its own host
summary: Drop, Agent voice and Voice search can run on OpenAI's realtime transcription with gpt-live-transcribe, the one live OpenAI model offered, with the key the OpenAI LLM routes already use; recorded audio goes to gpt-transcribe; routes on the other OpenAI transcription models move to these two; the batch rung uses /v1/audio/transcriptions; Meetings get no OpenAI model; a legacy OpenAI choice migrates to OpenAI instead of Soniox.
status: confirmed
tags: [byok, speech, openai, realtime, routing, privacy]
canonical_for: [openai-speech-provider]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer asked why the OpenAI models were missing from the Speech picker, saying they needed to test how the models behave in the Dynamic Island, and then approved bringing OpenAI back, through the orchestrating session (ORCH-TASK 73).
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: On 2026-11-22, after testing gpt-live-transcribe in build 1711 (very accurate and smooth, in his words), the maintainer approved narrowing OpenAI speech to gpt-live-transcribe for live dictation and gpt-transcribe for recorded audio, through the orchestrating session (ORCH-TASK 73, revision 3).
    confirmed_at: 2026-11-22
  - type: url
    reference: https://developers.openai.com/api/docs/guides/realtime-transcription (with the speech-to-text guide, deprecations and pricing pages), read 2026-11-22.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/OpenAIRealtimeAdapter.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/Streaming/BYOK/OpenAIRealtimeAdapterTests.swift
    confirmed_at: 2026-11-22
related: [2026-10-18-no-default-realtime-host.md, 2026-11-22-shared-model-rows.md, 2026-11-22-speech-model-prices.md]
---

# OpenAI is a speech provider again

## Context

OpenAI was removed from the speech providers on 2026-06-23
(`docs/decisions/2026-06-23-byok-models-ui-cleanup.md`). The reason was
technical: the realtime session ran push-to-talk (`turn_detection: null`)
with `gpt-4o-transcribe`, which only transcribes after the commit. During a
long hold no partial came back, the 6 s stall detector read that as a
half-open socket, and the take fell to batch recovery. A stored OpenAI choice
was then read as Soniox, which moved audio to a provider the user had not
chosen whenever a Soniox key was stored. Since then API & Models gave OpenAI
an account and a key (`byok.openai.llm_api_key`) for LLM routes and Subtitles'
Audio translate, but not for speech.

The maintainer wants to try OpenAI's speech models in the island.

## Decision

- `AIFeature.modelUse`: OpenAI serves the live speech features (Drop Fast,
  Drop Smart, Agent voice, Voice search). Meetings stay without an OpenAI
  model.
- The key is the shared OpenAI key. The retired speech credential
  `byok.openAI.api_key` of older builds is never read, so a key the user once
  removed does not come back.
- The socket goes to `BYOKRealtimeURL.openAIHosted`
  (`wss://api.openai.com/v1/realtime?intent=transcription`), only from a route
  on the OpenAI account. A server route keeps `openAIRealtime(baseURL:)`
  without a default host.
- Models: two, on the maintainer's decision after testing the first build.
  `gpt-live-transcribe` (registry) streams words within one turn for every
  live feature: push-to-talk, one commit when the take ends. `gpt-transcribe`
  (registry, recorded) takes Drop's batch rung and Retry. The pickers offer
  only these (`ModelRegistry.offersOnlyBuiltInModels`); the catalog leaves
  out `gpt-realtime-whisper`, the deprecated `gpt-4o-transcribe`,
  `gpt-4o-mini-transcribe`, `whisper-1` and the diarizing model.
- A saved route on any of those, or on `gpt-transcribe` for a live feature,
  moves at every launch (`AIRoutingStore.narrowOpenAISpeechModelsIfNeeded`)
  to `gpt-live-transcribe` on a live feature and `gpt-transcribe` on a
  recorded one, on the same account and key; text routes on OpenAI stay. The
  row then reads as a working one, with no check to repeat.
- The adapter still runs a turn-based model with server VAD (OpenAI commits
  a turn at every pause, text appears after each pause, the picker says
  "text after each pause", the take's end commits the rest). The pickers no
  longer offer one; the path stays for a route the launch move cannot rewrite
  (a routing document waiting for its backup copy is not rewritten).
- Session fields follow the model, per OpenAI's guide: `languages` and
  `keywords` for `gpt-live-transcribe`, `languages` and `prompt` for
  `gpt-transcribe`, no prompt for `gpt-realtime-whisper`, `language` and
  `prompt` for the older models. A server keeps its unchanged shape.
- The session tracks turns by `item_id`: deltas add up to the turn's partial,
  completed turns become finals in commit order (OpenAI does not order
  completions of different turns).
- The take's end has a deterministic tail. The app's final commit carries
  `event_id` `whytap_final_commit`; with server VAD it is followed by
  `input_audio_buffer.clear`. OpenAI handles client events in order, so its
  `cleared` answer comes after every commit made from the take's audio,
  automatic or the app's own: the take ends once `cleared` has arrived and
  every committed turn is transcribed. A late `committed` of an automatic turn
  can no longer end it early. Only `input_audio_buffer_commit_empty` for the
  app's own commit (its `event_id`, or none) means nothing is left; any other
  error after the end, such as a late `invalid_value`, fails the take.
- Every 2 s the OpenAI session pings the socket; a pong repeats the current partial,
  which the stall detector counts as progress and the island ignores. A pause
  in speech therefore no longer degrades the take, while a dead socket still
  does.
- An OpenAI `error` or failed turn is `providerRefused`, which Drop treats like
  a broken connection: the take's own audio goes to the batch rung, which
  either delivers or names the refusal ("OpenAI refused the key", "OpenAI:
  out of credit", "OpenAI is busy, try again") through `ProviderFailure`. The
  batch path reads only allowlisted `error.code` / `error.type` values, so a
  429 naming `credit_balance_exhausted` or `insufficient_quota` is out of
  credit, and any other 429 a rate limit.
- A user's server keeps its earlier contract: the plain commit, a refusal that
  stays terminal (`"provider"`), a failed turn ignored and no pings. Only its
  partials now add up the deltas of a turn.
- Logs name only allowlisted error codes and event types (`unlisted`,
  `other` otherwise): a server can put any text in those fields.
- Batch rung, Retry and agent batch voice: `/v1/audio/transcriptions` on
  api.openai.com with the shared key, always with `gpt-transcribe`.
- Drop auto-stop does not start on a turn-based OpenAI model (its first words
  can arrive after more than five seconds), like a server.
- A legacy OpenAI choice of the old Models tab migrates to the OpenAI account,
  only when the shared OpenAI key exists, and then onto `gpt-live-transcribe`
  by the move above; Meetings stay Not set. `selectedProvider` no longer reads it as Soniox.
- Costs: OpenAI's published per-minute prices, marked ≈ (live models $0.017,
  `gpt-transcribe` $0.0045, `gpt-4o-transcribe` and `whisper-1` $0.006,
  `gpt-4o-mini-transcribe` $0.003; the older prices still price past
  events). The pickers show the per-minute price
  ([speech model prices](2026-11-22-speech-model-prices.md)). The OpenAI key
  tile reads "Speech and LLMs". The catalog cache version is 6, so OpenAI's
  list refreshes once with the two models.

## Why

- The June reason no longer holds for the right models: OpenAI's current live
  models stream deltas as speech arrives, and the turn-based ones show text per
  phrase with server VAD. The silent pauses that tripped the stall detector are
  covered by the ping.
- Two models: the maintainer tested `gpt-live-transcribe` in the island and
  found it accurate and smooth. The other live models add choices without a
  reason to pick them: `gpt-realtime-whisper` costs the same, and the
  turn-based ones are deprecated and show text only after pauses.
  `gpt-transcribe` is OpenAI's current file model, so recorded audio needs no
  other. Moving saved routes by role keeps everyone dictating, with nothing
  to fix by hand.
- Invariant 3: audio goes only to the provider the user chose. Reading a stored
  OpenAI choice as Soniox broke it; keeping it OpenAI, or Not set without the
  OpenAI key, does not.
- One OpenAI key for speech and text is what users expect from the tile; the
  old separate credential stays retired so nothing is revived silently.
- Meetings: no OpenAI model labels speakers in realtime, the diarizing file
  model is deprecated by OpenAI (shutdown 2027-02-26), and the file endpoint
  takes 25 MB (about 13 minutes of 16 kHz PCM). An OpenAI meeting would be a
  transcript without speakers that fails on long calls.

## What we tested

- TDD on the session over a socket stub: streaming deltas into one turn,
  server-VAD turns completed out of order, the last phrase after the take's
  end, silence (empty final and empty commit), a dropped socket, account
  refusals after the end, a failed turn, the ping heartbeat, and a Drop take
  refused mid-recording resolving `.degraded` with its audio.
- Session fields per model and a server's unchanged shape; OpenAI's host only
  from the OpenAI account, a broken server URL failing before any socket, a
  server batch never on api.openai.com.
- Batch: the request contract on api.openai.com, 401 and 429 named as
  "OpenAI refused the key" and "OpenAI is busy, try again".
- Shared Speech row: one pick sets the four live features, Meetings reported as
  "OpenAI can't serve Meetings"; the OpenAI picker section lists the live
  models and turn-based catalog models, not the diarizing one.
- Migration: a legacy OpenAI choice with the shared key goes to OpenAI with its
  model; with only the retired key it stays Not set and never goes to Soniox.
- Mutation: disabling the empty-commit rule and flushing finals in completion
  order failed 4 of the session tests; reverted.
- The builder's offline probes (queue ticket 407) found five cases in the first
  version: a late automatic `committed` ending the take before the tail, a
  late `invalid_value` read as silence, a server's refusal sent to batch
  recovery, `credit_balance_exhausted` read as busy and raw error codes in
  public logs. All five are fixed and covered: the probes pass, the first one
  with the `cleared` answer OpenAI sends to the tail `clear`.
- Two models: the OpenAI picker section lists only `gpt-live-transcribe`
  with its price, the catalog leaves out the retired models, saved routes on
  each of them (and `gpt-transcribe` on a live feature, a dated snapshot of a
  retired model, `whisper-1` on Meetings) move by role and persist, the live
  model, text routes, other providers and a server naming `whisper-1` stay,
  a second launch writes nothing, and a moved route's row reads `.ok`
  (`OpenAISpeechModelsTests`, `ModelStatusResolverTests`,
  `SharedModelRowsTests`, `AIRoutingMigrationTests`).
- Offline fixtures cover the allowlisted empty-commit error code and
  per-model request fields. Acceptance with a live OpenAI request in the
  island remains.

## Rejected

- Only `gpt-4o-transcribe` and `gpt-4o-mini-transcribe` as first asked: they
  are deprecated (shutdown 2027-02-26) and with push-to-talk they are exactly
  the June dead end. They were first left available from the catalog with
  server VAD; after testing, the maintainer chose the two current models.
- Keeping every OpenAI transcription model in the pickers: more choices with
  no reason to pick them, and deprecated ones among them.
- Server VAD for every model: `gpt-live-transcribe` and `gpt-realtime-whisper`
  refuse turn detection.
- OpenAI Meetings through the realtime adapter: one hour in a single turn
  without speakers, with unknown limits.
- Reviving `byok.openAI.api_key` or keeping two OpenAI keys.
- Raising the stall threshold for every provider instead of the ping: it would
  slow the detection of a dead socket everywhere.

2026-11-22, PR: see the merge commit of this decision.
