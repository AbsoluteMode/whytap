---
id: silent-meetings-2026-10-18
type: decision
title: A meeting without speech is finished, not failed
summary: A recording without recognised speech from a completed Soniox job stores a "No speech detected" note and releases the staged audio instead of failing. The local half was removed with the on-device models.
status: confirmed
tags: [meetings, soniox, local, recovery]
canonical_for: [silent-meeting-outcome]
verified_at: 2026-10-18
sources:
  - type: repository
    reference: Sources/Sidekey/Meetings/SonioxMeetingTranscriber.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingBYOKProcessor.swift
    confirmed_at: 2026-10-18
  - type: repository
    reference: Tests/SidekeyTests/Meetings/MeetingBYOKProcessorTests.swift
    confirmed_at: 2026-10-18
related: [2026-10-18-delete-meeting-and-staged-audio.md, 2026-10-18-provider-batch-transcription.md, 2026-09-07-soniox-meeting-files.md, 2026-10-18-meeting-recovery-dark-wake.md, 2026-10-18-remove-local-models.md, 2026-10-22-no-retained-meeting-audio.md, 2026-11-19-meeting-transcript-kept.md]
---

# Silent meetings

> Update 2026-10-18: the local pipeline described below was removed with the
> [on-device models](2026-10-18-remove-local-models.md); its files and tests no
> longer exist. The Soniox rule remains current.

## Context

Meeting Notes kept producing failed meetings with "Soniox returned no
speaker-attributed transcript. The audio is saved for retry." In 24 hours the
local log had 12 such failures and 2 Keychain failures (OSStatus -25320,
errSecInDarkWake), all from two recordings of 3-4 seconds. Their audio was
the room noise floor: about -55 dBFS RMS, peak -30 dBFS, while speech is
about -30 to -20 dBFS RMS.

The completed Soniox job contained no speech, so the attribution check threw.
The meeting was marked failed and its manifest stayed staged. Launch recovery
runs twice per launch and again on every full wake, including dark wake. Each
retry read the same completed job, failed the same way and never deleted the
remote job or file.

The fully local pipeline had the same gap with a different symptom. When
Parakeet recognised no speech on either track, the processor threw "Local
transcription produced no speech on either track." It removes the staging
directory, including the manifest, after any error, so the meeting was not
retried; it stayed a failed row.

## Decision

A completed job whose transcript has no text and no tokens with text, apart
from end markers, decodes to an empty result. The checkpoint stores that
result like any transcript, and the remote job and file are deleted. The
BYOK processor then stores a plain "No speech detected" note with an empty
transcript, without calling the LLM, and removes the staging directory
(audio, manifest and checkpoint).

Speech without speaker labels remains a processing error, as decided in
2026-09-07-soniox-meeting-files.md.

The local pipeline applies the same rule after transcription. When Parakeet
ran and neither track contains recognised text, the processor evicts the
transcription model and stores the same note with an empty transcript. It
does not load the diarizer or the LLM, and it removes the staging directory
as after any local result. Silence requires a model run: when neither track
has readable audio, the transcriber throws instead of returning an empty
result. A track without audio, such as system audio that was never captured,
adds nothing to check; an unreadable track is treated the same way. A model
failure, a model that is not downloaded and Core ML or MLX errors remain
errors. Recognised text that cannot be aligned, such as system-track text
without token timings, still fails.

## Rationale

Silence is a final result, not an outage. The same audio returns the same
empty transcript on every retry, the same rule Drop uses: an empty batch
means silence. Keeping silence retryable produced repeated log errors and
red failed rows, which the UI cannot delete. It also caused Keychain reads
during dark wake and leaked Soniox resources. The note keeps the recording
visible, so a long recording made with a muted microphone does not disappear
without explanation.

Locally, an empty result proves silence only after the model has run. An
empty transcript without a model run would hide missing audio, and an
empty result after alignment would hide speech that could not be aligned.

## Verification

Unit tests cover:

- silence payloads, including a payload that has only an end marker, decode
  to an empty result;
- a completed silent job deletes the remote file and job, and its checkpoint
  is reused with no network requests;
- the processor stores the note without an LLM request, marks it ready
  without a failure reason, and removes the staged audio and manifest;
- speech without speaker labels still throws.

All new tests failed before the change with the production error message.
The full suite then passed: 2,950 tests, 8 skipped, 0 failures. The audio
of both staged recordings was measured locally.

Local pipeline tests cover:

- a silent local recording stores the note without the diarizer or an LLM
  request, evicts only the transcription model and removes the staged audio
  and manifest;
- through the coordinator, the meeting becomes ready without a failure
  reason, and no manifest remains for recovery;
- a transcription failure still marks the meeting failed;
- system-track speech without token timings still throws;
- the transcriber throws when neither track has audio, without calling the
  engine.

Before the change, the silent recording failed with the production message,
and the transcriber returned an empty result for two empty tracks. The
coordinator test also showed the old outcome: a failed meeting whose staged
audio and manifest had already been removed, so nothing could retry it. With
the local change, the full suite passed: 2,956 tests, 8 skipped, 0 failures.

Not verified:

- the actual Soniox response bodies for those two jobs. They were not fetched,
  so the Keychain key was never read outside the app.
- the installed app recovering both recordings after an update.
- real Parakeet output for a silent local recording. If the model returns
  words for room noise, the recording is not silent and still goes through
  the diarizer and the LLM, as before.

## Alternatives

- Keep the failure but stop retrying. Rejected: this leaves a permanent red
  row that the UI cannot delete, and its "recording is saved" reason would be
  false after cleanup.
- Discard silent recordings entirely. Rejected: a long meeting recorded with
  a muted microphone would vanish without explanation.
- Delete remote resources on every decode failure. Rejected: each launch and
  wake would then upload the recording again and pay for another
  transcription of unattributed speech.
- Apply the same rule to the realtime BYOK adapters. Not done: they are not
  part of the observed failure, and a realtime adapter can also end empty
  after an aborted stream, so its empty result does not prove silence.
- Detect local silence from the aligned transcript. Rejected: alignment drops
  system-track text without token timings, so recognised speech would become
  a "No speech detected" note.
- Run the diarizer before the local silence check. Rejected: silence has
  nothing to attribute, so loading the model would only cost time and memory.
- Keep local audio after a failed run so recovery can retry it. Not done
  here: the local processor deletes both raw tracks after every error to
  protect privacy, so local model failures are not retried. Changing that
  trades privacy for retries and needs its own decision.

2026-10-18, PR https://github.com/AbsoluteMode/exodia/pull/16; local pipeline:
PR https://github.com/AbsoluteMode/exodia/pull/19.
