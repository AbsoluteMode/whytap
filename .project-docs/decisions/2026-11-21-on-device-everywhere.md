---
id: on-device-everywhere-2026-11-21
type: decision
title: On this Mac for every speech feature, Meetings and Subtitles included
summary: The On this Mac speech model can now be chosen for Meetings and Subtitles audio as well as the microphone features. Both run it through OnDeviceStreamingAdapter, which cuts the stream into phrases at pauses and decodes each phrase once; Meetings get a transcript without speaker labels.
status: confirmed
tags: [byok, local, models, meetings, subtitles, settings, privacy]
canonical_for: [on-device-speech-adapter]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user asked that the local transcription model be selectable everywhere the app transcribes, not only in Drop, and that places where it cannot work be explained rather than hidden.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Streaming/OnDevice/OnDeviceStreamingAdapter.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/AIRouting/AIFeature.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Streaming/OnDevice/OnDeviceEverywhereTests.swift
    confirmed_at: 2026-11-21
related: [2026-11-19-on-device-dictation.md, 2026-11-28-on-device-model-preparation.md]
---

## Context

The [on-device dictation decision](2026-11-19-on-device-dictation.md) offered
On this Mac to Drop Fast, Drop Smart, Agent voice and Voice search only. It
left out Meetings (no speaker labels without a diarizer) and Subtitles audio
(system audio goes through a provider's real-time adapter, which the model did
not have). The user wants the local model wherever the app transcribes.

Places that transcribe and how they choose a model, all in Settings → API &
Models through `AIFeature.modelUse(on:)` and `FeatureRouteResolver`:

- Drop Fast, Drop Smart, Agent voice, Voice search: `TranscriptionSessionFactory`
  (On this Mac already built `OnDeviceTranscriptionSession`), batch recovery
  and Retry through `ProviderBatchTranscriber` → `OnDeviceBatchTranscriber`.
- Meetings: `MeetingBYOKProcessor` — Soniox's file API, otherwise the route's
  real-time adapter fed the recording chunk by chunk (`MeetingBYOKTranscriber`).
- Subtitles audio: `LiveSubtitleModel` — the route's real-time adapter fed
  CoreAudio system audio.
- Translation, Subtitles translation, Meeting notes, Drop Smart cleanup and
  Agent are text models, not transcription.

The only barrier was `modelUse(on: .onDevice)` returning nil for Meetings and
Subtitles audio, and `RealtimeAdapterFactory` having no adapter for `thisMac`.

## Decision

- `OnDeviceStreamingAdapter` implements the real-time adapter contract on this
  Mac. `OnDevicePhraseSegmenter` cuts the 16 kHz stream into phrases: a phrase
  ends after 700 ms of quiet following speech (quiet is below about -44 dBFS
  or within 9 dB of a slowly rising floor), or at 12 s, cut at the quietest
  20 ms frame of its last 4 s. Consecutive phrases cover the whole stream, so
  quiet speech the detector misses is still decoded. Each phrase is decoded
  once (`.final`); digital silence is not decoded, and a piece under 0.3 s
  (Parakeet's minimum) is padded with silence rather than dropped. A phrase
  that decodes to nothing clears the live text. A failed live preview is
  ignored; only a failed final ends the stream with an error.
- Subtitles ask for live text: the phrase in progress is re-decoded about once
  a second while nothing else waits (`.partial`). Meetings do not.
- Decodes run in order on one worker. `sendAudio` waits while two finished
  phrases are queued, so a meeting read from disk faster than real time holds
  a few phrases in memory, not the recording.
- `modelUse(on: .onDevice)` is `.realtimeSTT` for every speech feature, so the
  picker, the offer after a download and the removal rule cover Meetings and
  Subtitles audio unchanged. The model is still the credential: without it the
  route is Not set and nothing moves to a provider.
- Meetings on this Mac go through the existing adapter branch of
  `MeetingBYOKProcessor`, like a user's own server: one transcript without
  speaker labels. The Meetings picker says "without speakers" under the model.
- `makeMetered` returns the adapter unwrapped for `thisMac`: no Costs rows.

## Why

- One adapter reuses both consumers unchanged; `MeetingBYOKProcessor` and
  `LiveSubtitleModel` needed no on-device branch.
- Parakeet decodes whole buffers. Phrase-sized buffers stay on its constant-
  cost single-pass path (under 15 s) and give subtitles complete sentences to
  translate, which is what the provider finals gave them.
- Speakers need a diarizer, which the 2026-10-18 removal of local models took
  out on purpose. A transcript without speakers is what a user's own server
  already gives a meeting; the picker states it instead of hiding the option.

## What we tested

Scenario tests with a fake decoder (`OnDeviceEverywhereTests`): the model is
offered to every speech feature and to no text feature; picking it for
Meetings and Subtitles audio sticks and survives a relaunch; a download offers
it to both; removing the model un-sets them and moves nothing; choosing
Deepgram again builds Deepgram's adapter with its key; without the model the
route is `missingKey`, Subtitles fail on the Subtitles audio row before system
audio is captured and a meeting fails as a missing credential with its
recording kept; a meeting on this Mac is transcribed with a URL session that
fails the test on any request and gets its notes; subtitles turn decoded
phrases into translated lines; phrases split at pauses, cover the stream and
stay under 12 s; finals keep their order; trailing silence is not decoded;
live text appears only for subtitles; a decode failure ends the stream with an
error; a fast reader is held back.

An independent review (Codex) of the first version found four defects, fixed
before the PR with a test each: a sub-0.3 s tail after a length cut was
dropped; a failed live preview discarded the queued final; a phrase decoding
to nothing left stale live text on screen; a length cut reset the quiet count
and delayed the next pause. The real model was not run on a live
meeting or live system audio here.

## Known limits

- No speaker labels for a meeting on this Mac.
- A meeting with no speech on this Mac fails with "no transcript" like other
  adapter routes, not the Soniox "No speech detected" note.
- Background music with no pauses gives 12 s phrases cut at the quietest
  moment, which can still split a word.
- The pause thresholds are not tuned on real recordings yet.

## Rejected

- A separate recorded transcriber for meetings on this Mac (decode each chunk
  file): duplicates the phrase cutting and would conflict with the parallel
  move of Meetings to pre-recorded provider APIs; the adapter branch already
  exists and stays for user servers.
- Hiding On this Mac in Meetings because it has no speakers: the user asked
  for the choice; the picker names the limit.

2026-11-21.
