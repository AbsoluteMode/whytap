---
id: soniox-meeting-files-2026-09-07
type: decision
title: Transcribe completed Soniox meetings through the file API
summary: Replace realtime bulk audio sends with resumable asynchronous file transcription.
status: confirmed
tags: [meetings, soniox, transcription, recovery]
canonical_for: [soniox-meeting-transcription]
verified_at: 2026-09-07
sources:
  - type: repository
    reference: Sources/Sidekey/Meetings/SonioxMeetingTranscriber.swift
    confirmed_at: 2026-09-07
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingBYOKProcessor.swift
    confirmed_at: 2026-09-07
  - type: url
    reference: https://soniox.com/docs/stt/async/async-transcription
    confirmed_at: 2026-09-07
related: [../project.md]
---

# Soniox meeting file transcription

## Context

Completed meetings sent all recorded PCM frames through the realtime dictation
adapter without pacing, then started consuming events. A 53-minute recording
failed during the audio send with a transport error. Its finalized manifest
and complete audio remained on disk. This realtime path is inappropriate for
bulk processing, although the exact remote socket-close reason was unavailable.

## Decision

Use Soniox's authenticated Files and Transcriptions APIs with stt-async-v5 for
Soniox BYOK meetings. Dictation retains its realtime adapter; other meeting
providers retain their existing behavior. Stream validated 16 kHz mono PCM16
recorder chunks into one on-disk multipart WAV upload, preserving order and
rejecting malformed or incompatible chunks. No public audio URL is created.

Store uploaded file ID, transcription ID, and eventually transcript in an
atomic mode-0600 checkpoint beside the finalized recording. Resume an existing
job after transport failure or restart. Poll queued/processing jobs with a
30-minute processing deadline; individual requests also have timeouts. Save
transcript before remote cleanup or note generation, so an LLM failure does not
require another transcription. Delete our own remote job and file after text
is durable; keep source audio until the existing local note-store insertion
succeeds. No API keys or transcript content enter diagnostic logs.

A terminal provider error attempts remote cleanup and retains local audio.
POST requests are not automatically retried because their completion may be
ambiguous. A crash between successful remote creation and checkpoint write can
still leave an orphan resource; the API offers no creation idempotency key.

## Verification

Tests cover multipart WAV length/order, invalid audio rejection, upload/poll/
cleanup, reuse without network, resuming an existing job, timeout, transport
failure, and terminal provider errors. Recovery of historical cloud queues
requires their mixed track only; concatenating mixed, mic and system tracks
would triple the audio. Back up the database and source audio before migration,
preserve the original meeting identity/timestamps, and create a finalized
manifest for the local BYOK pipeline. No retired Whytap backend is contacted.
