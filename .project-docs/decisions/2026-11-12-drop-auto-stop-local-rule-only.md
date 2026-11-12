---
id: drop-auto-stop-local-rule-only-2026-11-12
type: decision
title: Only the quiet rule ends an auto-stop Drop take; provider turn prediction was removed
summary: With auto-stop on, ElevenLabs scribe_v3_live takes were cut and pasted at about 36 s of continuous speech, because the provider's segment-cap commit was read as the end of the turn. Every take now uses a manual commit and ends only by the local quiet rule.
status: confirmed
tags: [drop, dictation, auto-stop, elevenlabs, turn-prediction, segment-commit]
canonical_for: [drop-auto-stop-end-of-speech]
verified_at: 2026-11-12
sources:
  - type: user-confirmed
    reference: On 2026-11-12 the user reported that automatic stop misbehaved and switched it off, then approved the fix that ends a take only by the local rule.
    confirmed_at: 2026-11-12
  - type: runtime-log
    reference: Build 1619 unified log, 2026-11-12. Two consecutive auto-stop takes on scribe_v3_live resolved at 35,810 ms and 35,922 ms with no key release.
    confirmed_at: 2026-11-12
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/ElevenLabsBYOKAdapter.swift
    confirmed_at: 2026-11-12
  - type: repository
    reference: Sources/Sidekey/AppDelegate.swift
    confirmed_at: 2026-11-12
  - type: repository
    reference: Tests/SidekeyTests/DropAutoStop/HandsFreeTakeTests.swift
    confirmed_at: 2026-11-12
related: [2026-11-11-drop-auto-stop.md]
---

# Only the quiet rule ends an auto-stop take

## Context

Drop auto-stop (2026-11-11) asked ElevenLabs `scribe_v3_live` for
`commit_strategy=turn_prediction` and treated the provider's first commit with
words as the end of the take. That decision listed one open risk: Scribe
commits a segment at its length cap of about 36 s
(`docs/decisions/2026-06-30-elevenlabs-byok-segment-commit-truncation.md`).

The risk was real. On build 1619 two consecutive auto-stop takes ended at
35.8 s and 35.9 s with no key release, in the middle of speech, and were
pasted. A commit carries nothing that tells a predicted end of turn from the
segment cap.

## Decision

- Every ElevenLabs take uses `commit_strategy=manual`, auto-stop included.
  A provider commit is a segment of live text and never ends a take.
- An auto-stop take ends only by `DropAutoStopRule`: the live transcript stops
  changing for the quiet period (default 2 s,
  `com.sidekey.drop.autoStop.quietSeconds`), or no words arrive within 5 s. The
  stop is the ordinary one, so the manual commit joins every segment, as in a
  take ended by the key.
- **A connection lost before the stop is recovered, not delivered.** With
  manual commit, ElevenLabs reports the segments it holds as done when its
  socket closes. For an auto-stop take this now follows the existing rule for
  every take (`AppDelegate.resolveDelivery`): a transcript that arrives
  without a requested stop is a fragment, so the retained audio is
  batch-transcribed and the fragment is only the fallback. Tried and dropped:
  degrading the session on an early done event to keep capturing; it left
  manual takes waiting for a stop that the early result used to make
  unnecessary (`testDoneResolvesToTranscript`).
- Removed: the hands-free adapter path (`handsFree`, `endsTurnItself`,
  `makeMeteredHandsFree`) and the `providerSilenceSeconds` default. A stored
  value of that default is ignored.

## Why

- One end-of-speech rule for every provider, on a path already proven for
  long dictations.
- Turn prediction had never been confirmed on a live socket, and its only
  observed effect was the truncation.

## What was tested

- `testASegmentCommitMidSpeechKeepsAnAutoStopTakeRunning`: a commit at 36 s
  followed by more speech keeps the session running, the rule keeps listening,
  and the stop delivers both segments.
- `testAConnectionLostAfterASegmentIsRecoveredFromTheRetainedAudio`: a
  segment, more speech, then a closed socket before any stop: the session
  reports the fragment with the audio retained, and delivery pastes the batch
  transcription of that audio, never the fragment.
- `testEveryTakeAsksForAManualCommit`, `testProviderCommitsNeverEndATakeBeforeItsStop`.

## Not verified

- A live auto-stop dictation longer than 36 s on the installed app.
- Whether partials pause for longer than the quiet period inside continuous
  speech; if they do, raise `quietSeconds`.

## Rejected

- Treating a commit as the end only when no words follow it: the quiet rule
  already is that check, without a second timer.
- Keeping turn prediction and sending our own commit on stop: unverified
  against the provider in that mode.

## Unchanged

The streaming session's no-progress resolve stops any resilient Drop take
after 12 s without provider progress, auto-stop or not
(`docs/decisions/2026-06-22-byok-noprogress-deadlock.md`). On a provider that
sends nothing during silence, 12 s of silence therefore ends a Toggle take.

2026-11-12, branch `claude/drop-auto-stop-long-takes`.
