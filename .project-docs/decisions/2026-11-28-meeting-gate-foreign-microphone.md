---
id: whytap-meeting-gate-foreign-microphone-2026-11-28
type: decision
title: A microphone held only by another app no longer defers an install
summary: The install gate defers on Whytap's own audio capture, unreadable input users and incomplete snapshots. Identified foreign apps (browsers, call apps, Discord, anything else) never defer, for input or output.
status: confirmed
tags: [build, queue, builder, install, meetings]
canonical_for: [builder-meeting-gate-foreign-microphone]
verified_at: 2026-11-28
supersedes_in_part: 2026-11-24-meeting-gate-whytap-activity.md
sources:
  - type: user-confirmed
    reference: On 2026-11-28 a local install waited over half an hour because a browser held the microphone during a demo broadcast while Whytap recorded nothing. The owner said that if the microphone is held not by our program (a meeting or real-time transcription), Whytap can restart.
    confirmed_at: 2026-11-28
  - type: repository
    reference: scripts/build-queue-meeting-gate.swift
    confirmed_at: 2026-11-28
related: [2026-11-24-meeting-gate-whytap-activity.md, ../processes/shared-app-development.md]
---

# Meeting gate: foreign microphone does not defer

## Context

The 2026-11-24 gate kept three rules for other apps: a known call app defers
(Whytap might be about to record it), a browser microphone defers, an unknown
microphone user defers. A browser broadcast held the microphone for over half
an hour and blocked an owner-local install although Whytap was idle.

## Decision

Order in `classify`:

1. Whytap (`com.rootwise.sidekey`, beta and helpers by prefix) with input: busy,
   `whytap_capturing_audio`. Unchanged; covers meetings, Notes, dictation, agent
   voice and Subtitles because all of them capture inside Whytap's process.
2. Any input user whose bundle ID is unreadable: busy, `microphone_in_use`
   (it might be Whytap).
3. Incomplete snapshot: unknown (an unreadable process might be Whytap).
4. Otherwise clear: every active input user is positively another app. Output
   of any app is ignored (it cannot be Whytap capturing). The reason string
   `no_call_audio_observed` is kept because `build-queue-meeting-gate.py` checks it.

The Discord and CoreSpeech lists and the call-app and browser lists are removed:
they no longer change any verdict.

## Why

The gate protects what an install interrupts, which is only Whytap's own work.
Whytap's input flag shows that positively; foreign audio says nothing about it.
Both consumers (`owner-local.py` and the builder's promotion and watcher) run
the same `build-queue-meeting-gate.py`, which runs this Swift probe, so there is
no second copy of the rule.

## Accepted loss

The gate cannot see a shown "Take notes" nudge or the 45-second meeting
reconnect window (Whytap captures nothing then). An install in those seconds
relaunches Whytap and drops the offer; a finished recording is already saved.
Whytap exposes no activity state outside its process; adding one would need an
app change and was not done. A signal for it is a future option.

## Rejected

- Keep call apps deferring: the owner's rule is about Whytap's own activity.
- Treat unidentified input as foreign: could be Whytap with an unreadable bundle ID.

## Tested

`swift scripts/build-queue-meeting-gate.swift --self-test`: 30 cases (Whytap
with browser/Zoom/Discord alongside, browser/call/unknown mic alone, foreign
output, unreadable bundle, incomplete snapshots).

2026-11-28, ORCH-TASK 120.
