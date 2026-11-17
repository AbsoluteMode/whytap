---
id: live-text-rewrites-2026-11-15
type: decision
title: A provider rewrite keeps the recording wing's line in place
summary: When the speaker stumbled and the provider rewrote earlier live text, the line in the recording wing jumped. The old and new text are now matched from both ends, the reveal point stays on the same character, and a change in the line's length is eased over about a third of a second.
status: confirmed
tags: [island, dictation, live-transcript, animation]
canonical_for: [recording-wing-live-text-rewrites]
verified_at: 2026-11-17
sources:
  - type: user-confirmed
    reference: On 2026-11-17 the maintainer reported repeated gathering of already displayed letters and asked to keep attention on the current speech.
    confirmed_at: 2026-11-17
  - type: user-confirmed
    reference: On 2026-11-15 the user reported that when they stumble and the provider changes a letter near the start, the line in the wing jumps, and asked for a fix.
    confirmed_at: 2026-11-15
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/LiveTextTicker.swift
    confirmed_at: 2026-11-15
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandLiveTextTickerView.swift
    confirmed_at: 2026-11-15
  - type: repository
    reference: Tests/SidekeyTests/LiveText/LiveTextTickerTests.swift
    confirmed_at: 2026-11-15
related: [2026-11-13-live-text-sand.md]
---

# Rewrites keep the line in place

## Context

`LiveTextTicker` (2026-11-13) compared the old and new live text character by
character at the same index, and kept the reveal point as a plain count.
Providers rewrite text they have already sent: a repeated word is taken back,
a word is heard differently. When such a rewrite changed the length of the
text before the reveal point:

- the count pointed at a different character, so several characters of the
  tail appeared or disappeared in one frame;
- every character after the change differed at its index, so the whole rest
  of the line was either gathered again or swapped at once;
- the end of the line moved by the width difference in one frame.

The user saw this as the line jumping whenever they stumbled.

## Current behavior (2026-11-17)

A common example is a capitalized first word and a newly appended word in
the same snapshot. A comparison of only the two ends groups the already
visible words with the new word and makes them gather a second time.

- Correct the visible span immediately. Preserve the original reveal time
  of unchanged runs, and pace newly delivered text past the reveal point.
  Bound the interior edit search to 512 characters on each side; very large
  replacements use a short unique anchor at the live edge when available.
  A final punctuation mark carried to a new clause does not reveal that clause early.
- Restore the matching visible part when a provider briefly retracts a tail.
  The ticker retains one previous visible prefix within the current take.
  Restoring visible characters does not count as newly arriving speech.
- In a full wing, compensate a changed scroll position only when its visible
  prefix survives. Taper the adjustment to zero at the live edge so the
  current word stays visible. A short line keeps its left origin.
- Soniox emits final tokens followed by a partial tail for each token frame.
  Publish its combined snapshot once at that boundary. A final-only frame
  still publishes through its empty partial. Segment-based providers continue
  to publish individual finals.

## Original decision (2026-11-15)

- Old and new text are matched by their common start and common end. Only the
  part between them is treated as rewritten.
- Characters after the rewritten part keep their reveal state and do not
  gather again.
- A rewrite before the reveal point moves the point by the length difference,
  so it stays on the same character. A rewrite that contains the point pulls
  it back to the end of what was visible of the replaced part; the rest is
  paced as new text.
- Rewritten visible characters gather in place; more than 12 swap at once
  (unchanged rule, now counted on the rewritten part only).
- When a rewrite moves the end of the revealed line, the difference is added
  to a slide that decays with a 0.12 s time constant, so the line glides to
  its new place instead of jumping.

## Why

- A rewrite in live speech is almost always local, so matching both ends
  finds it without a full diff.
- The slide is applied only at rewrites. Ordinary growth does not move the
  end (new text is not revealed yet), so steady scrolling has no added lag.

## What was tested

- `testAStumbleTakenBackKeepsTheRestInPlace`,
  `testAWordInsertedEarlierGathersAloneAndKeepsTheRevealPoint`,
  `testARewriteBeforeTheRevealPointDoesNotRevealOrHideTheTail`,
  `testTextReplacedAtTheRevealPointIsPacedAgainFromThere`,
  `testALongRewriteChangesAtOnce`.
- `testTheLineSlidesInsteadOfJumpingWhenARewriteChangesItsLength`: the end of
  the line is unchanged on the frame of the rewrite, moves under 4 pt in the
  next frame and settles at the shorter line.

## Not verified

- The look in the running app, and whether this was the only jump the user
  saw: no recording of the reported case was examined.
- When the line overflows the wing its end stays at the right edge, so text
  to the left of a rewrite still shifts by the width difference at once.

## Rejected

- Easing the scroll offset every frame: it would leave the newest character
  behind the wing's edge during steady speech.
