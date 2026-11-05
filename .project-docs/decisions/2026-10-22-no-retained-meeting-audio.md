---
id: no-retained-meeting-audio-2026-10-22
type: decision
title: Keep meeting audio only while it can still become a note
summary: Staged meeting audio exists only while a meeting is recorded and processed; a failed recording is retried for 24 hours after its last chunk and then deleted, directories without a manifest go an hour after their last write, a stored meeting keeps no audio even without its note, and all builds remove retired research audio.
status: confirmed
tags: [meetings, storage, privacy, recovery, disk]
canonical_for: [meeting-audio-retention]
verified_at: 2026-11-05
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user said meeting audio should not be stored and is only useful for debugging in development builds; on 2026-10-22, answering the retention proposal, the user repeated that recordings are not to be kept.
    confirmed_at: 2026-10-22
  - type: trace
    reference: Metadata on the maintainer's Mac (du, ls, file dates and meeting ids/statuses; no audio read) on 2026-10-21 — meetings-staging 2.3 GB in 44 directories, none with manifest.json, none written after 2026-10-18 06:17, all mixed tracks of already processed meetings (13 by id, 31 cloud-era matched by start time in the 2026-10-18 inventory); retired research captures totaled 845 MB in 7 sessions from 2026-10-20 and 2026-10-21.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsCoordinator.swift
    confirmed_at: 2026-10-22
  - type: repository
    reference: Sources/Sidekey/Meetings/RetiredMeetingCaptureCleanup.swift
    confirmed_at: 2026-11-05
  - type: repository
    reference: Tests/SidekeyTests/Meetings/MeetingsStagedAudioRetentionTests.swift
    confirmed_at: 2026-10-22
related: [2026-10-18-delete-meeting-and-staged-audio.md, 2026-10-21-backup-essentials-only.md, 2026-10-18-silent-meetings.md, 2026-10-18-meeting-recovery-dark-wake.md, 2026-10-20-meeting-continuations.md]
---

# Keep meeting audio only while it can still become a note

## Context

Backups stopped carrying meeting audio on 2026-10-21; whether the app should
keep it at all was left open. The app deleted a staged recording only after a
successful note. Everything else stayed in `Sidekey/meetings-staging` for good:

- a failed recording (no route or key, provider or model error, refusal,
  Soniox timeout) kept its audio and manifest and was retried on every launch
  and full wake, with no end;
- a ready row without a note dropped only its manifest and kept the audio,
  which nothing reads without a manifest;
- leftovers of the retired cloud pipeline and of manual repairs
  (`orig-mixed-*`, `manifest.json.held-*`, `*.pre-realign-*`, written by agents,
  never by the app) were invisible to recovery.

On the maintainer's Mac that was 2.3 GB of mixed tracks of meetings that
already had notes. The internal research capture added another 845 MB in two
days of calls and never deleted anything. The user decided that recordings are
not to be kept; audio is debugging material for development builds.

## Decision

- Staged audio exists only while a meeting is recorded and processed. Success
  and "No speech detected" delete it at once, as before.
- A failed recording keeps its audio and manifest for retries until 24 hours
  after its last chunk (`MeetingsCoordinator.failedRecordingRetention`). The
  next launch or full wake after that deletes the directory; the meeting stays
  listed as failed with `recordingExpiredMessage` and is never retried. An
  expired part of a reconnected meeting leaves the stored note untouched and
  sets the meeting ready again (it may have been updating or failed), unless
  another part of that meeting is still recording, processing or staged; a
  recording whose note was already committed is set ready.
- A directory named by a recording id without `manifest.json` goes one hour
  after its last write (`unmanagedRecordingGrace`); with an undecodable
  manifest it gets the 24-hour window instead.
- Launch recovery of a stored meeting removes the whole staged directory,
  including a ready row without a note.
- Recordings restored from an archive made before 2026-10-21 arrive with their
  manifest parked (`manifest.json.restored-inactive`), so they count as
  directories without a manifest and go at the first launch or wake an hour
  after the restore wrote them. The restore comment that "the bytes are still
  there to recover from" now holds only for that hour; backup code is
  unchanged.
- The sweep runs at the start of launch recovery, also with Meeting Notes
  switched off. It skips the active recording, a recorder that is still
  starting (its directory exists while the microphone start may wait for the
  permission answer), a live Reconnect part, recordings being processed and
  entries not named by a UUID. Listing, dating and removal run off the main
  thread; use is rechecked after every suspension. An unreadable directory
  listing or modification date leaves its age unknown and keeps the recording.
- Research capture was retired on 2026-11-05. All builds remove its old
  diagnostic-audio directory at launch; no flag enables capture.
- Development builds keep no extra copy of processed audio.

## Why

- A note and its transcript are the durable result of a meeting; audio after
  that is only a privacy and disk cost.
- Retries need the audio, and most failures are transient (network, provider
  outage, key added later). A day covers an evening offline or a key set up the
  next morning without turning a permanent failure into permanent storage.
- The window counts from the newest chunk: chunks are written only while
  recording, while every retry rewrites the manifest and the Soniox checkpoint,
  whose dates would extend the window forever. An interrupted Reconnect part
  has no end time in its partial manifest, but its chunks do.
- Without a manifest nothing can recover a directory, so keeping it helps no
  one. The hour margin protects a recording that has no manifest until Stop
  and the moment between Stop and the manifest write; the active recorder and
  a live Reconnect part are excluded by id as well.
- Every remaining leftover on the maintainer's Mac belonged to a meeting with a
  note (two independent inventories), so the first launch frees 2.3 GB without
  losing a meeting.
- Research audio is debugging material. Keeping it out of packaged builds
  follows the same rule as the main pipeline.

## Tested

`MeetingsStagedAudioRetentionTests` drives launch recovery over real files with
backdated modification times and a real `MeetingsStore`:

- a failure from 23 hours ago is retried and keeps its audio;
- a failure whose last chunk is 25 hours old, with a manifest and checkpoint
  rewritten a moment ago, loses its directory, is not processed on two launches
  and stays failed with the expiry reason;
- an expired Reconnect part keeps its meeting's note and leaves the meeting
  ready whether it was ready, updating or failed; with a newer part of the
  same meeting still staged the status is left to that part; an expired first
  recording without a note stays failed with the expiry reason;
- with Meeting Notes off, an expired failure and a manifest-less leftover go,
  a recent failure stays and nothing is processed;
- a leftover with `orig-mixed-*`, held manifest and pre-realign checkpoint goes
  after two hours; a fresh one stays; an undecodable manifest stays for two
  hours and goes after 25; directories and files not named by a recording id
  stay;

`RetiredMeetingFeatureTests` verifies that retired research audio is removed
without touching ordinary meeting files.

`MeetingsCoordinatorLifecycleTests` keeps the directory of a running recording
whose files are three hours old, and of a recording whose microphone start
is still waiting; that recording then starts into it. With the starting-id
protection or the newer-part check removed, the matching tests fail. `MeetingsStagedAudioCleanupTests` now expects
a ready row without a note to lose its audio. Success-path deletion stays
covered by `MeetingBYOKProcessorTests`.

## Rejected

- Seven days for failed recordings: the user asked for no stored recordings;
  a week is storage, a day is a retry buffer.
- Deleting on the first failure: a transient outage would lose the meeting.
- Keeping processed audio for N days in development builds: the user wants no
  stored recordings; research capture was subsequently removed.
- A manual Retry button with indefinite retention: still unbounded storage.
- Recovering manifest-less directories as meetings: legacy leftovers would be
  processed again and duplicate existing notes at the user's expense. A
  partial manifest for every plain recording, so a crash during recording is
  recovered, remains a separate proposal.
- Cleaning remote Soniox files of an expired checkpoint: it needs the key and
  network at launch; the transcriber already deletes remote resources after
  every completed or failed job, so only a timed-out job can remain.

## Supersession

This replaces "a ready row without a note keeps its audio" in the
[delete-meeting decision](2026-10-18-delete-meeting-and-staged-audio.md); Delete
still never removes a staged directory by an unknown id. Research capture was subsequently removed on 2026-11-05. This closes the
open question at the end of the
[backup essentials decision](2026-10-21-backup-essentials-only.md).

2026-10-22 · PR AbsoluteMode/whytap#209
