---
id: openai-speech-provider-2026-11-22
type: decision
title: OpenAI is a speech provider again, on the shared OpenAI key and its own host
summary: Drop, Agent voice and Voice search can run on OpenAI's realtime transcription (gpt-live-transcribe by default, gpt-realtime-whisper, and the turn-based catalog models through server VAD) with the key the OpenAI LLM routes already use; the batch rung uses /v1/audio/transcriptions; Meetings get no OpenAI model; a legacy OpenAI choice migrates to OpenAI instead of Soniox.
status: confirmed
tags: [byok, speech, openai, realtime, routing, privacy]
canonical_for: [openai-speech-provider]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer asked why the OpenAI models were missing from the Speech picker, saying they needed to test how the models behave in the Dynamic Island, and then approved bringing OpenAI back, through the orchestrating session (ORCH-TASK 73).
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
related: [2026-10-18-no-default-realtime-host.md, 2026-11-22-shared-model-rows.md]
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
- Models: `gpt-live-transcribe` (registry, recommended) and
  `gpt-realtime-whisper` (registry) stream words within one turn: push-to-talk,
  one commit when the take ends. The catalog's turn-based models
  (`gpt-transcribe`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`,
  `whisper-1`) run with server VAD: OpenAI commits a turn at every pause, so
  text appears after each pause (the picker says "text after each pause"), and
  the take's end commits the rest. The diarizing model is left out.
- Session fields follow the model, per OpenAI's guide: `languages` and
  `keywords` for `gpt-live-transcribe`, `languages` and `prompt` for
  `gpt-transcribe`, no prompt for `gpt-realtime-whisper`, `language` and
  `prompt` for the older models. A server keeps its unchanged shape.
- The session tracks turns by `item_id`: deltas add up to the turn's partial,
  completed turns become finals in commit order (OpenAI does not order
  completions of different turns). After the take's end in server-VAD mode an
  error that is not an account refusal (key, credit, rate, model) means the
  final commit found an empty buffer: nothing is left, the take is done.
- Every 2 s the session pings the socket; a pong repeats the current partial,
  which the stall detector counts as progress and the island ignores. A pause
  in speech therefore no longer degrades the take, while a dead socket still
  does.
- An OpenAI `error` or failed turn is `providerRefused`, which Drop treats like
  a broken connection: the take's own audio goes to the batch rung, which
  either delivers or names the refusal ("OpenAI refused the key", "OpenAI is
  busy, try again") through `ProviderFailure`.
- Batch rung, Retry and agent batch voice: `/v1/audio/transcriptions` on
  api.openai.com with the shared key; the live-only models map to
  `gpt-transcribe`, a file-capable model is kept.
- Drop auto-stop does not start on a turn-based OpenAI model (its first words
  can arrive after more than five seconds), like a server.
- A legacy OpenAI choice of the old Models tab migrates to the OpenAI account
  with its stored model, only when the shared OpenAI key exists; Meetings stay
  Not set. `selectedProvider` no longer reads it as Soniox.
- Costs: OpenAI's published per-minute prices, marked ≈ (live models $0.017,
  `gpt-transcribe` $0.0045, `gpt-4o-transcribe` and `whisper-1` $0.006,
  `gpt-4o-mini-transcribe` $0.003). The OpenAI key tile reads "Speech and
  LLMs". The catalog cache version is 5, so OpenAI's list refreshes once and
  shows the speech models.

## Why

- The June reason no longer holds for the right models: OpenAI's current live
  models stream deltas as speech arrives, and the turn-based ones show text per
  phrase with server VAD. The silent pauses that tripped the stall detector are
  covered by the ping.
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
- Not tested live: no paid request was made. The exact name of the empty-commit
  error code and the per-model field acceptance come from OpenAI's docs; the
  session does not depend on the code's name. Acceptance in the island remains.

## Rejected

- Only `gpt-4o-transcribe` and `gpt-4o-mini-transcribe` as first asked: they
  are deprecated (shutdown 2027-02-26) and with push-to-talk they are exactly
  the June dead end. They stay available from the catalog, with server VAD.
- Server VAD for every model: `gpt-live-transcribe` and `gpt-realtime-whisper`
  refuse turn detection.
- OpenAI Meetings through the realtime adapter: one hour in a single turn
  without speakers, with unknown limits.
- Reviving `byok.openAI.api_key` or keeping two OpenAI keys.
- Raising the stall threshold for every provider instead of the ping: it would
  slow the detection of a dead socket everywhere.

2026-11-22, PR: see the merge commit of this decision.
