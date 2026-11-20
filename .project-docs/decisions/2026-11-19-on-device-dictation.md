---
id: on-device-dictation-2026-11-19
type: decision
title: Dictation on this Mac as a provider, speech only
summary: An "On this Mac" provider runs Parakeet TDT v3 through FluidAudio for the microphone features (Drop Fast, Drop Smart, Agent voice, Voice search). It is a route like any provider's, chosen per feature; the downloaded model is its credential. No on-device LLM, diarizer or meeting pipeline returns.
status: confirmed
tags: [byok, local, models, drop, settings, privacy]
canonical_for: [on-device-speech]
verified_at: 2026-11-19
sources:
  - type: user-confirmed
    reference: On 2026-11-19 the user asked to build dictation that works out of the box first, after a comparison with other dictation apps showed that needing a provider key before the first dictation is the main barrier for a new user.
    confirmed_at: 2026-11-19
  - type: repository
    reference: Sources/Sidekey/Streaming/OnDevice/OnDeviceSpeechModelStore.swift
    confirmed_at: 2026-11-19
  - type: repository
    reference: Sources/Sidekey/Streaming/OnDevice/OnDeviceTranscriptionSession.swift
    confirmed_at: 2026-11-19
  - type: repository
    reference: Tests/SidekeyTests/Streaming/OnDevice/OnDeviceDictationTests.swift
    confirmed_at: 2026-11-19
related: [2026-10-18-remove-local-models.md, 2026-10-19-api-and-models.md, 2026-10-18-legacy-model-cleanup.md, 2026-10-18-provider-batch-transcription.md]
---

## Context

Every other dictation app a new user compares Whytap with produces text within
a minute of installing it: a local model or a free tier. Whytap asked for a
provider account and key first. On-device models were removed on 2026-10-18
([remove local models](2026-10-18-remove-local-models.md)); the cost there was
MLX Qwen (gigabytes, `mlx.metallib`, its own Gatekeeper constraints), the
diarizer and the local meeting pipeline, not speech recognition. FluidAudio is
still linked for the meeting detector's Silero VAD, and Parakeet runs on it
through Core ML with no further dependency.

## Decision

- A new provider kind `onDevice` ("On this Mac") with one account, `thisMac`,
  and one model, `parakeet-tdt-v3`. It is a route in API & Models like any
  other: chosen per feature, never a global Local level.
- It serves the microphone features only: Drop Fast, Drop Smart, Agent voice
  and Voice search. Not Meetings (speaker labels come from the provider), not
  Subtitles (system audio through a provider adapter), not any text feature.
- The downloaded model is the account's credential. `OnDeviceSpeechReadiness`
  answers where a key lookup would; without the model the route fails with
  `missingKey`, the row shows Not set, and nothing is sent to a provider.
- The API keys tab has an On this Mac tile (Apple Silicon only) whose form
  downloads or removes the model (about 470 MB, from Hugging Face, into
  `Application Support/Sidekey/OnDeviceSpeechModels`). A finished download
  offers the model for features that have no model yet, through the existing
  "Use <Provider> for" window. It never changes a feature that already has a
  route. Removing the model un-sets the features that ran on it.
- `TranscriptionSessionFactory` builds `OnDeviceTranscriptionSession` for such
  a route: no adapter, no socket. Live text is a re-decode of the last 14 s
  about every 0.8 s; the pasted text is one pass over the whole take on stop.
  The batch rung, Retry and agent batch voice go through
  `OnDeviceBatchTranscriber`; a take latched on this Mac stays on this Mac.
- The loaded model is released after five idle minutes; loading it again
  takes about 0.1 s.
- Costs records nothing for on-device takes. Backups do not include the model.

## Why

- The first dictation no longer needs an account anywhere. That was the gap
  against every comparable app.
- Speech alone brings back none of what made local models expensive to keep:
  no MLX, no metallib, no new package, no gigabyte LLM.
- A provider in the existing routing reuses its rules unchanged: one route
  per feature, no silent switch, Not set when the credential is gone. The old
  global Local level needed its own migration edge cases.
- FluidAudio's `language` argument is a script filter that drops tokens of
  the other script. A Latin-script language keeps it. A Cyrillic-script
  language passes none, so a Russian take is not forced into Cyrillic.

## What we tested

- 2026-11-19, M4 Pro, macOS 27.2, through the new code
  (`OnDeviceSpeechEndToEndTests`, opt-in): download and first load 74 s;
  three synthetic 2.5-3 s phrases decoded in 78-92 ms each, offline after the
  download. Russian and English came out verbatim (the Russian letter yo is written as ye).
- In a mixed Russian phrase containing "GitHub" and "pull request", both
  terms came out transliterated into Cyrillic, with and without the script
  filter. English terms inside Russian speech are transliterated by the model
  itself. Not measured on a live voice.
- Scenario tests with a fake decoder (`OnDeviceDictationTests`): route without
  any key, missing model with a provider key stored, the offer after a
  download, removal, a take latched before a route change, silence, decode
  failure, Escape, a dead microphone, and that no on-device path makes a
  network request.

- An independent review of the first commit found eight defects, fixed in
  the second: a take past the engine's 20 MB turn buffer (about 11 minutes)
  was pasted cut short, so the session keeps its own copy of the stream; live
  text counted a scrolled window as new text, which held Drop auto-stop
  through a pause, so only a changed ending counts; idle eviction or Remove
  could unload the model under a decode, so decodes hold the model
  (`acquire`/`release`); a download finishing replaced another provider's
  open offer; partial decodes kept running after stop.

## Known limits

- FluidAudio answers a failed model load by deleting the files and
  downloading them again. The load has a 60 s deadline: past it the take
  fails and the tile offers Download again, but a short re-download can still
  start without a click. Avoiding it needs a load path that never downloads.
- English terms inside Russian speech are transliterated by the model.

## Follow-up: its own card

The first build showed On this Mac as one more tile among the keys. Its status
line "Download model" read as a button and did nothing: the real button was in
a form under the row of tiles, often below the visible area. On the user's
feedback the same day it became a card above the tiles, titled as its own
block, with the one action (Download, Cancel or Remove) in the card and motion
for the download (a progress bar with a travelling highlight, a pulsing arrow,
a checkmark that bounces once). Reduce Motion leaves a plain bar and symbol.
The card was checked in offscreen renders of all four states in both
appearances, not in a running app.

On 2026-11-20 the user saw the installed card sit on "0% of about 470 MB" and
took the download for stalled; it was running and reached 37% shortly after.
Until the first whole percent the card now says "Starting…" and a highlight
travels the whole track (an empty bar with Reduce Motion). Why the first
percent arrives late was not investigated; the number is still the provider
library's own progress.

## Rejected

- Apple's system speech (`DictationTranscriber`): reports Russian and English
  on the test Mac, but needs macOS 26 and its quality is not measured. It can
  be added as a second model of this provider after a comparison.
- An on-device LLM for Smart cleanup: the cost that was removed on 2026-10-18.
  Ollama and LM Studio already work as the user's own server.
- A first-run "dictate without a key" button and a "try it" field: useful,
  but separate UI; this change is the provider and its tile.
- Routing a keyless new user to this Mac automatically: a route changes only
  by the user's choice.
- On-device Meetings: no speaker labels without a diarizer.

2026-11-19.
