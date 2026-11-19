---
id: meeting-transcript-kept-2026-11-19
type: decision
title: Keep a meeting's transcript when its note fails
summary: A meeting's transcript is stored before the notes model is asked. A failed note leaves the transcript readable with a fixed reason and Retry notes; retries never transcribe again, and the transcript outlives the 24-hour audio retention.
status: confirmed
tags: [meetings, transcript, errors, retention, byok]
canonical_for: [meeting-kept-transcript]
verified_at: 2026-11-19
sources:
  - type: user-confirmed
    reference: On 2026-11-19 the user asked what happens to a meeting when transcription is configured and the notes provider has run out of credit, and approved keeping the transcript in that case.
    confirmed_at: 2026-11-19
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingBYOKProcessor.swift
    confirmed_at: 2026-11-19
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsStore.swift
    confirmed_at: 2026-11-19
  - type: repository
    reference: Tests/SidekeyTests/Meetings/MeetingBYOKProcessorTests.swift
    confirmed_at: 2026-11-19
related: [2026-10-22-no-retained-meeting-audio.md, 2026-10-18-silent-meetings.md, 2026-10-20-meeting-continuations.md]
---

## Context

A meeting is processed in two paid steps: the speech provider transcribes the
recording, then the notes model writes the note. The transcript and the note
were stored together, in one commit, only after the note existed. When the
notes model failed (out of credit, a refused key, an outage), the user had
paid for the transcription and saw nothing: the meeting was Failed, the
Transcript tab was empty, and the note pane showed the provider's raw error
text. Each retry transcribed again on every provider except Soniox, whose
checkpoint file lives next to the audio. After 24 hours the audio and that
checkpoint were deleted and the transcript was gone.

## Decision

- The processor stores the transcript (`meeting_pending_transcripts`, keyed
  by recording) as soon as it exists, before calling the notes model.
- An attempt that finds a kept transcript for its recording skips the speech
  provider, for every provider.
- A notes failure is reported as `MeetingNotesFailure`: fixed copy naming the
  cause, followed by "The transcript is saved". The provider's own message is
  never shown, because it can quote the transcript.
- The note pane of a failed meeting with a kept transcript enables the
  Transcript tab and shows Retry notes. The retry writes the note from the
  kept transcript without the recording.
- The 24-hour retention deletes the audio only. The kept transcript stays
  until the note is stored or the meeting is deleted.
- While the recording is still staged, Retry notes is the ordinary queued
  processing of that recording (it reuses the kept transcript). Once the
  audio is gone it writes the note from the kept transcript alone, with the
  current language preference as the hint.
- Only a first recording's kept transcript is shown. A Reconnect part's is
  reused on retry but not shown: its meeting still shows the earlier note.

## Why

- The transcript is the part of a meeting that cannot be made again once the
  audio is gone, and the user has already paid for it.
- A transcript in the meetings database survives the audio's retention rule
  without weakening it: no audio is kept longer than before.
- Retrying only the failed step costs the price of the note, not of the
  whole meeting.

## What we tested

- Notes out of credit (402): the transcript is readable, the failure text is
  the fixed copy without provider text, and a second attempt with a working
  notes model does not call the speech adapter again.
- A note written from the kept transcript after the recording is gone.
- An expired recording with a kept transcript keeps it and says so.
- Retry notes through the coordinator: success releases leftover audio; a
  repeated failure keeps the meeting failed with the new reason; a meeting
  that is not failed is refused.
- Deleting a meeting removes its kept transcript.
- An independent review of the first commit found seven defects, fixed in
  the second: Delete during Retry notes could bring the meeting back (delete
  is refused while notes are written, and a missing row aborts the retry);
  a retry cut short by quitting left the meeting stuck (launch sets it back
  to failed); with the recording still staged the button now runs the
  ordinary queued processing, which keeps the captured language and markers
  and cannot overlap launch recovery; the pane no longer stays on a spinner
  or jumps off the Transcript tab on refresh; a removed notes key with a
  kept transcript shows fixed copy; a continued call's part has its own
  wording and its kept transcript is dropped when its audio expires.
- The note pane was not seen in a running app; its model and tab state are
  covered by tests.

## Rejected

- Storing the transcript as a placeholder note: an edit of the placeholder
  would be saved as the real note.
- Showing a Reconnect part's kept transcript: it would hide the earlier note.
- Keeping the audio longer instead: it contradicts the audio retention rule.

2026-11-19.
