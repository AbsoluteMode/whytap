---
id: recorded-meeting-models-2026-11-21
type: decision
title: Meetings on ElevenLabs and Deepgram use their pre-recorded APIs with speakers
summary: A finished meeting on ElevenLabs or Deepgram goes to the provider's pre-recorded endpoint in one diarized request instead of being streamed through the real-time adapter; the Meetings picker offers recorded models and a saved ElevenLabs Meetings route on a streaming Scribe model moves to Scribe v3 at launch.
status: confirmed
tags: [meetings, elevenlabs, deepgram, models, routes, diarization]
canonical_for: [recorded-meeting-models]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user saw `scribe_v3_live` on the Meetings row and asked whether Meetings should use pre-recorded models. After the explanation that ElevenLabs and Deepgram meetings were streamed through the real-time adapter (no speakers), the user answered "Yes, move them" (in Russian) to moving them to the pre-recorded APIs, including moving saved ElevenLabs Meetings routes to Scribe v3.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Meetings/RecordedMeetingTranscriber.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingBYOKProcessor.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/AIRouting/AIRoutingStore.swift
    confirmed_at: 2026-11-21
  - type: url
    reference: https://elevenlabs.io/docs/api-reference/speech-to-text/convert (read 2026-11-21)
    confirmed_at: 2026-11-21
related: [2026-10-18-silent-meetings.md, 2026-11-20-elevenlabs-scribe-v3.md, 2026-10-18-provider-batch-transcription.md, 2026-10-19-api-and-models.md, 2026-11-22-drop-edit-learning.md]
---

## Context

Soniox meetings already went through its file API with an async model and
speaker labels. Deepgram and ElevenLabs meetings were read back from disk and
pushed through the real-time WebSocket adapter in 100 ms frames, so the
Meetings row offered streaming models (`scribe_v3_live`, `nova-3` as real-time)
and their transcripts had no speakers. `docs/specs/api-and-models.md` marked
moving them to batch APIs with speakers as a later proposal.

## Decision

- `RecordedMeetingTranscriber` sends the whole recording in one request:
  ElevenLabs `POST /v1/speech-to-text` (multipart, `diarize=true`, word
  timestamps, `no_verbatim`, `tag_audio_events=false`, language and
  vocabulary `keyterms` like the real-time request) or Deepgram
  `POST /v1/listen` (WAV body, `diarize`, `utterances`, the language policy
  and `keyterm`s of the real-time URL). The WAV is written once to the
  staging directory (`MeetingAudioUpload`, shared with Soniox) and uploaded
  from disk; the temporary file is removed afterwards.
- Words or utterances become speaker segments with Soniox's rule (new segment
  on a speaker change, a pause over 2 s or 1,000 characters), labelled
  `Speaker 1`, `Speaker 2`… Speech returned without labels is kept unlabelled
  rather than failing. An empty transcript is silence: the "No speech
  detected" note without the LLM, as for Soniox.
- Failures use fixed copy by status (refused key, no Speech to Text access,
  out of credit, busy, not responding, refused recording) and keep the audio
  staged for the retry; the provider's body is never shown. A refused request
  records no cost; a successful one records the audio seconds for Costs.
- ElevenLabs gets only the saved vocabulary terms its batch endpoint
  accepts (at most 50 characters and five words, none of `< > { } [ ] \`,
  at most 1,000 terms; words counted at every non-alphanumeric boundary).
  The vocabulary itself accepts terms outside these limits, which would make
  the whole request fail; they are left out of that request only.
- `AIFeature.meetings.modelUse` is `.asyncSTT` on Soniox, ElevenLabs and
  Deepgram (a user's server keeps `.realtimeSTT` and its adapter path). The
  registry recommends `scribe_v3` for Meetings, marks `nova-3` as both kinds
  and both recorded models as "with speakers". The async model check covers
  ElevenLabs and Deepgram.
- At every launch `AIRoutingStore.moveMeetingsToRecordedModelIfNeeded` moves a
  Meetings route on ElevenLabs naming a streaming Scribe model to
  `scribe_v3`: same account and key. At runtime
  `ModelRegistry.elevenLabsRecordedModel(for:)` also maps a streaming ID, so a
  route synced from an older Mac never reaches the endpoint with it. The same
  move runs after a Settings sync live reload (`reloadFromDefaults`), so the
  row, Check now and the recording agree; Check now also maps the ID.

## Why

The user chose it. Speaker labels are what make meeting notes usable
("who promised what"), and the pre-recorded APIs give them for the same
provider and key. One request also avoids pushing an hour of audio through a
live socket faster than real time. Moving the saved route is the same kind of
exception as the Scribe v3 upgrade: same provider, account and key, only the
model kind that the endpoint accepts.

## What was tested

- Unit and scenario tests with a stubbed URL session: request shape for both
  providers (fields, query, one WAV header, chunk order, key header), speaker
  grouping, silence, malformed answers, refusal copy without the provider's
  text, Costs event, no leftover upload file; processor paths for ElevenLabs
  with speakers reaching the stored transcript and the notes model, Deepgram
  silence, ElevenLabs out of credit keeping the audio, a server still using
  its adapter; launch migration and picker contents. Full suite run locally.
- The build queue's review of the first head reproduced two defects with real
  request building: vocabulary terms the batch endpoint refuses (six words,
  angle brackets) were sent, and after a Settings sync reload Check now sent
  `scribe_v3_live` to the batch endpoint. Both are fixed and covered by tests
  (including the builder's reproducer).
- Not checked: a real request with a key, ElevenLabs' encoding of repeated
  `keyterms` multipart fields (the docs show the list type but not the wire
  form), processing time for multi-hour recordings against the 30-minute
  request timeout, and whether ElevenLabs usage rows report `scribe_v3`.
  ElevenLabs keyterms carry a 20% surcharge (the real-time request already
  sent them).

## Rejected

- Keep streaming through the real-time adapter: no speakers and the picker
  shows a streaming model on a recorded feature.
- Reuse `ProviderBatchTranscriber`: it holds the whole take in memory and
  returns plain text without speakers.
- Leave the saved route on `scribe_v3_live` and map only at runtime: Settings
  would show a model that is not the one used.
- Move a user's own server too: its `/v1/audio/transcriptions` has no
  standard speaker labels; it keeps its real-time path.

2026-11-21.
