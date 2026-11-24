---
id: whytap-meeting-gate-whytap-activity-2026-11-24
type: decision
title: The meeting gate defers on Whytap's own capture and real call apps, not on Discord voice chat, and the owner can let one waiting install through
summary: Any microphone user no longer defers an install. Whytap's own audio capture, call apps, browsers with a microphone and unknown microphone users still do; Discord and macOS CoreSpeech do not. The owner's allow-install records a bounded override on the waiting ticket that never covers Whytap's own recording.
status: confirmed
tags: [build, queue, builder, install, meetings]
canonical_for: [builder-meeting-gate-whytap-activity, builder-meeting-gate-owner-override]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24, while build 1746 (ticket 520, PR 450) waited because Discord held the microphone, the maintainer refused to leave the Discord voice channel and told the orchestrator that the builder must stop waiting on it and do its work.
    confirmed_at: 2026-11-24
  - type: repository
    reference: scripts/build-queue-meeting-gate.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: scripts/build-queue-meeting-gate.py
    confirmed_at: 2026-11-24
  - type: repository
    reference: scripts/build-queue.py
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Meetings/CoreAudioSystemAudioSource.swift
    confirmed_at: 2026-11-24
related: [2026-10-20-meeting-aware-builder-refresh.md, 2026-11-23-builder-queue-group-install.md, ../processes/shared-app-development.md]
---

# Meeting gate: Whytap's own activity, and the owner's override

## Context

The gate deferred an install whenever any process had a running microphone
input. The maintainer sits in a Discord voice channel almost all day, so
builds 1744, 1745 and 1746 each waited half an hour or more. A live CoreAudio
read on 2026-11-24 showed two input users: `com.hnc.Discord.helper.Renderer`
(input and output) and `com.apple.CoreSpeech` (input). Neither is a meeting
that Whytap records: Whytap's meeting detector watches Zoom, Slack, Teams and
browsers, not Discord. There was also no way for the owner to say "I am not
in a meeting, install now".

An install quits and relaunches only Whytap. What it can break is what Whytap
itself captures: a meeting recording, a manual Notes take, dictation or
Subtitles. All of these run in Whytap's own process (`AVAudioEngine` for the
microphone, an in-process CoreAudio process tap with an aggregate device for
system audio), so CoreAudio reports Whytap's process as running input during
any capture, also with the microphone muted or off.

## Decision

The probe reads the bundle ID of every process with running audio and
decides in this order:

1. Whytap (`com.rootwise.sidekey`, the beta ID and helpers by prefix) with
   input: busy, `whytap_capturing_audio`. Nothing overrides it.
2. For every other input user: Discord (`com.hnc.discord`, Canary, PTB) and
   `com.apple.CoreSpeech` are ignored; a known call app is busy
   (`call_app_microphone_in_use`); a browser is busy
   (`browser_microphone_in_use`); an unidentified or unknown process is busy
   (`microphone_in_use`).
3. An incomplete snapshot stays unknown; output rules are unchanged (call app
   output busy, browser output unknown), except that Discord output is ignored.

The owner can let one waiting install through with
`build-queue.py allow-install --ticket N --by <owner> --said "<their words>"
[--minutes M]` (default 30, at most 120; `--revoke` ends it). The helper
refuses the configured builder, refuses a ticket that is not
`pending_install`, stores the override in the queue and records an event on
the ticket with who allowed it, when, until when, who recorded it and the
owner's words. The gate honours it only while it is current, that ticket is
still `pending_install` and three fresh snapshots could see every process;
Whytap's own capture still defers.

## Rationale

The gate protects what an install interrupts. Whytap's own input flag answers
"is Whytap recording now" directly from Whytap's process, without trusting
lists of other apps, and it covers every capture path. Real call apps still
defer because Whytap may be about to record them (its detector offers that)
and the maintainer named no change for them. An unknown microphone user still
defers because it may be a call app the list does not know; widening that is
the owner's call, available per install through the override.

CoreSpeech is macOS speech recognition; on this Mac it ran input alongside
Discord. Earlier installs passed with it because no process had running input
at those moments: the old rule treated every input alike and never looked at
bundle IDs, so CoreSpeech had no special handling before.

## Tested

- `swift scripts/build-queue-meeting-gate.swift --self-test`: 25 cases,
  including Discord with input and output, Discord with CoreSpeech, Whytap
  recording while Discord holds the microphone, Zoom, FaceTime, Teams,
  Telemost, a browser microphone, an unknown microphone user and an incomplete
  snapshot with Discord.
- `python3 scripts/build-queue-meeting-gate.py` on the maintainer's Mac with
  Discord in a voice channel and CoreSpeech running: `clear`. The old gate
  returned `busy / microphone_in_use` for the same state.
- `scripts/test-build-queue.py`: the override is recorded on the ticket,
  refused for the builder, for a ticket that is not waiting, without words or
  outside 1..120 minutes; the gate honours it only while current and while its
  ticket waits, and never over Whytap's capture or an unreadable snapshot.

## Rejected

- Ask Whytap over its MCP or CLI whether it records: needs the app to answer
  and a harness approval; a hung app would read as idle.
- Ignore every non-Whytap microphone user: would also pass unknown call apps
  that Whytap might be about to record; not asked for.
- A standing "not in a meeting" switch: easy to forget on; the override is
  tied to one waiting ticket and expires.

## Limits

After this change an install can still interrupt what matters to the user
when: a call runs in an app that is neither Whytap nor on the call list and
holds no microphone (listen only); a work call takes place in Discord, which
Whytap does not record, so the install only relaunches Whytap; the owner's
override is used during a call that Whytap is not yet recording (Whytap's
offer to record that call is lost for the restart); or Whytap is about to
start a recording in the seconds between the gate and the quit.

2026-11-24, ORCH-TASK 102.
