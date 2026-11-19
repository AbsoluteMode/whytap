---
id: live-text-rewrite-hold-2026-11-19
type: decision
title: A rewrite of visible live text waits half a second before it is shown
summary: Providers rewrite live text they have already sent, sometimes taking words back and returning them a moment later. The recording wing now holds a snapshot that changes visible text for 0.5 s and shows the newest one in one step; new words at the end are not delayed.
status: confirmed
tags: [island, dictation, live-transcript, animation]
canonical_for: [recording-wing-live-text-rewrite-hold]
verified_at: 2026-11-19
sources:
  - type: user-confirmed
    reference: On 2026-11-19 the user said that providers (ElevenLabs and others) rewrite chunks, that the user should see the rewrite but without the jerking, and proposed applying rewrites in batches, about once a second.
    confirmed_at: 2026-11-19
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandLiveTextTickerView.swift
    confirmed_at: 2026-11-19
  - type: repository
    reference: Tests/SidekeyTests/LiveText/LiveTextTickerTests.swift
    confirmed_at: 2026-11-19
related: [2026-11-15-live-text-rewrites.md, 2026-11-13-live-text-sand.md]
---

# Rewrites of visible text are held briefly

## Context

A screen recording of 2026-11-19 showed the live line in the recording wing
jerking: the provider dropped a clause of three words for a fraction of a
second and returned it. The same day's change to
[rewrites](2026-11-15-live-text-rewrites.md) made the line move as rigid
pieces, but every intermediate snapshot was still drawn, so a clause taken
back and returned moved the line twice.

## Decision

`IslandLiveTextTickerModel.textArrived` compares each snapshot with the text
already revealed on screen.

- A snapshot that starts with the revealed text (new words at the end, or a
  change in text not revealed yet) is shown at once and cancels a waiting
  rewrite.
- A snapshot that changes revealed text waits. The wait starts at the first
  such snapshot and lasts `rewriteHoldSeconds` (0.5 s); later snapshots
  replace the waiting one. When the time is up the newest one is shown in one
  step, with the rigid-piece glide.

The rule is the same for every provider: only the text is compared.

## Why

- The user wants to see the correction, without the motion of each
  intermediate step. A clause that returns within the hold is never shown
  changing; a correction that stays appears once.
- Half a second, not the proposed second: while a rewrite waits, new words in
  the waiting snapshots are not shown either, and the pacer's reserve of
  delivered text lasts about 0.6 s between batches. A longer hold would stop
  the line.

## What was tested

- `testWordsTakenBackAndReturnedQuicklyAreNeverShownChanging`,
  `testARewriteThatStaysIsShownOnceAfterTheHold`,
  `testARewriteOfTextNotYetRevealedIsNotHeld`.

## Not verified

- The look in the running app with each provider.
- Whether 0.5 s covers the usual time a provider takes to return words: one
  recording was examined.

## Rejected

- A fixed timer that applies all text once a second: it would delay new words
  too and make the line stop and start.
- Holding the rewrite in the streaming session: paste, auto-stop and the plain
  text fallback read the provider's text and must not be delayed.

2026-11-19, PR https://github.com/AbsoluteMode/whytap/pull/298
