---
id: meeting-transcript-without-notes-model-2026-11-28
type: decision
title: A meeting without a notes model keeps its transcript and is not failed
summary: When the Meetings route can transcribe but Meeting notes has no model (none chosen, or its key missing), the meeting is transcribed and stored as an ordinary ready meeting with a fixed "transcript only" note, its audio is released, and Make notes writes the notes later from the stored transcript.
status: confirmed
tags: [meetings, transcript, errors, retention, byok, on-device]
canonical_for: [meeting-without-notes-model]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 the owner installed Whytap on a clean Mac with only the Parakeet speech model; meetings ended as failed. The owner chose "Transcript only: without a model for notes the meeting is saved with its transcript and no error; notes can be made later when a model appears."
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingBYOKProcessor.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsStore.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/Meetings/MeetingBYOKProcessorTests.swift
    confirmed_at: 2026-11-28
related: [2026-11-19-meeting-transcript-kept.md, 2026-10-18-silent-meetings.md, 2026-10-20-meeting-continuations.md, 2026-10-22-no-retained-meeting-audio.md, 2026-10-18-delete-meeting-and-staged-audio.md, 2026-10-20-meeting-ready-notifications.md]
---

## Context

A meeting needed both a Meetings route and a Meeting notes route. With only a
speech model (for example Parakeet on a clean Mac without keys), the detector
still offered to take notes, and after the recording the meeting was marked
failed with "Choose models for Meetings and Meeting notes…": nothing was
transcribed, the audio stayed staged for 24 hours and was then deleted.

## Decision

- `shouldProcessDirectly` needs only a Meetings route.
- No notes model means: no Meeting notes route, a route without a model, or
  a route whose provider key is missing (`OpenRouterLLMError.meansNoNotesModel`).
  Then the recording is transcribed (speakers as the speech provider gives
  them) and stored through the ordinary `storeProcessedRecording` with the
  fixed note `MeetingBYOKProcessor.transcriptOnlyMarkdown` and the title
  "Meeting transcript". The row is ready, without a failure reason. The staged
  audio, manifest and provider checkpoint are released like after any finished
  meeting: the notes need only the transcript.
- The coordinator emits `meetingTranscriptAvailable` (notification "Meeting
  transcript is ready") instead of a failure.
- The note pane never opens the fixed note in the editor. It shows a calm
  explanation with a document icon, Make notes (the shared Retry notes button)
  and the Transcript tab. MCP reads and search treat the fixed note as no note.
- Make notes (`MeetingsCoordinator.retryNotes` on a ready meeting) writes the
  notes from the stored transcript, every part of a continued call, without
  the speech model, and replaces the fixed note only while it is unchanged. A
  failure (no model yet, refused key, out of credit) is kept as the ready row's
  failure reason and shown on the pane; the row is never moved back to failed
  (the store never moves ready back).
- A continued call without a notes model adds its transcript and keeps the
  meeting's note. A continued call of a transcript-only meeting is always
  stored transcript-only, so Make notes covers all parts at once.
- Unchanged: a configured notes route that fails while the meeting is
  processed (refused key, out of credit, network, a server without address)
  fails the meeting with its transcript kept, as in
  [2026-11-19](2026-11-19-meeting-transcript-kept.md). With no notes model and
  a Meetings route that cannot transcribe (Parakeet not downloaded, missing
  speech key) or no Meetings route, the meeting fails with
  `processorNotConfiguredMessage` and its audio stays staged.

## Why

- The owner chose it: transcription only is fine, an error is not.
- A transcript is useful by itself, and it is what any later note is made of.
- A real note file keeps every invariant that says a ready meeting has a note
  (backups refuse a ready row without one, launch recovery treats a ready row
  as finished, older builds read it as a plain note after a rollback). This is
  the precedent of the "No speech detected" note.
- Releasing the audio follows the retention rule: audio stays only while it
  can still become a note, and here the note no longer needs it.

## What we tested

Scenario tests through the real processor and coordinator, with the Meetings
route on this Mac (Parakeet) and a fake speech adapter: a meeting without a
notes model finishes ready with its transcript, a transcript event and no
failure, audio released, readable by MCP and search, unchanged by a relaunch;
Make notes before a model keeps it ready with the reason, after a model is
added writes the notes once from the stored transcript and takes their title;
a failing model on Make notes keeps it ready; a continued call without a model
joins the transcript and Make notes covers both parts; a meeting with notes
continued without a model keeps its notes; a staged meeting that failed as
not configured becomes transcript-only on launch; a configured notes model
failing during processing still fails; nothing that can transcribe still
fails as not configured. The pane is covered by controller tests; it was not
seen in a running app.

## Rejected

- A ready row without a note and a kept transcript: backups and launch
  recovery treat it as damage, and a continued call could not attach to it.
- A new progress status: older builds could not decode the row after a
  rollback.
- Keeping the meeting failed with a softer message: the owner did not want an
  error.
- Making the notes automatically when a model appears: it would spend the
  user's credit on old meetings without asking.

2026-11-28.
