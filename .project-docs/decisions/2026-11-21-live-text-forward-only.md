---
id: live-text-forward-only-2026-11-21
type: decision
title: The live line in the recording wing only scrolls forward
summary: ElevenLabs removes repeated words and false starts from text it has already sent and sometimes cuts the end of a phrase for a moment. The line scrolled back to press its shorter end against the right edge, which moved the whole line backwards. The scroll position now only moves forward for text that stays on screen; free space is left at the right edge for new words.
status: confirmed
tags: [island, dictation, live-transcript, animation, elevenlabs]
canonical_for: [recording-wing-live-text-scroll-direction]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user reported that with ElevenLabs the right wing still sometimes jerks back while text is flowing normally, and asked to analyse how ElevenLabs sends its chunks.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandLiveTextTickerView.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/LiveText/ElevenLabsRecordedTake.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/LiveText/ElevenLabsLiveTextReplayTests.swift
    confirmed_at: 2026-11-21
related: [2026-11-19-live-text-rewrite-hold.md, 2026-11-15-live-text-rewrites.md, 2026-11-13-live-text-sand.md]
---

# The live line only scrolls forward

## Context

After the rigid-piece glide and the half-second hold of rewrites
([2026-11-15](2026-11-15-live-text-rewrites.md),
[2026-11-19](2026-11-19-live-text-rewrite-hold.md)) the user still saw the
line jerk back with ElevenLabs.

A live `scribe_v3_live` session was recorded on 2026-11-21 with the app's own
query (`commit_strategy=manual`, `no_verbatim=true`) and synthetic speech: a
scripted text with hesitations and repeated words, 42 s, 132 partial and 2
committed events. It is kept as `ElevenLabsRecordedTake`. What it shows:

- Every partial is the whole current segment, decoded again. 62 of 132
  partials are not a continuation of the previous one.
- About half of the partials end with a provisional mark (`-` for a word in
  progress, `.`, `?`, `...`) that the next partial replaces.
- `no_verbatim` removes repeated words and false starts after they were sent.
  The segment became shorter by 6 to 30 characters three times, each time
  in the last 10 to 30 characters.
- A comma far behind the live word appears and disappears on alternate
  partials.
- The end of the phrase was cut for a moment and returned (92 to 78 to 104 to
  81 characters within one second).
- The committed text of a segment differs from the last partial (a finished
  word, a final mark). The first partial of the next segment can be a
  hallucinated word that the following partial replaces.

Replayed through the session's join and the ticker at 60 frames per second,
the three shortenings moved unchanged visible letters to the right in 45
frames: the revealed line became 66, 111 and 147 pt shorter, and the scroll
position, defined as "the end of the line is at the right edge", followed it.
The glide made this a quarter-second travel backwards instead of a jump.

## Decision

The scroll position is a value of its own (`scroll`, the text coordinate at
the wing's left edge) instead of a function of the revealed width.

- During steady speech it follows the end of the line once the end reaches
  the right edge, and never decreases.
- A rewrite keeps one piece of the line where it is. That piece is the
  unchanged tail when the change began left of the wing, or when longer text
  is written before at least 24 pt of words at the live edge. Otherwise it is
  the text before the change.
- A shorter rewrite therefore leaves the text before it in place. The words
  after it glide left to close the gap, and the free space stays at the right
  edge until new words fill it.
- A longer line that no longer fits glides forward to show its end.
- A line cut so short that less than a quarter of the wing would show
  glides back until a quarter shows. This is the one case where visible text
  moves back: an almost empty wing reads as lost text.
- Words revealed after a rewrite are drawn in their own place; only the words
  that were on screen after a shorter rewrite glide to close its gap.

The rule is the same for every provider.

## Why

- The user reads the line as moving in one direction. A line that travels
  back reads as an error even when it is smooth.
- Free space at the right edge already exists in the design: before the wing
  is full, the capsule keeps its widest extent through shorter revisions.
- The shortenings are real corrections, so hiding them is not an option; the
  half-second hold still collapses the ones that return.

## What was tested

- `testTheRecordedTakeNeverMovesVisibleTextBackwards`: on the recording no
  unchanged visible letter moves right by 0.75 pt or more in a frame (before
  the change: 45 frames, up to 49 pt in one frame).
- `testTheRecordedTakeEndsOnTheProvidersTextWithItsEndInView`,
  `testTheRecordingContainsShorterPartialsAndRewrittenTails`.
- `testHoldingRewritesDoesNotMakeTheRecordedTakeStandStillMoreOften`,
  `testAProvisionalMarkAtTheLiveEdgeIsReplacedAtOnce`,
  `testARewriteDeeperThanTheLastTwoCharactersIsStillHeld`,
  `testNewWordsAfterAShorterRewriteDoNotSnapTheLine`,
  `testWordsAfterACutEndAreNotDisplaced`.
- `testAWordRemovedMidLineNeverMovesTheStartBack`,
  `testAShorterPartialLeavesTheLineWhereItIs`,
  `testCommittedTextAfterAPartialOnlyMovesTheLineForward`,
  `testPunctuationToggledBehindTheLiveWordNeverMovesTheLineBack`.

## Not verified

- The look in the running app.
- A take with a human voice. The recording is synthetic speech; real speech
  has more hesitations, so the events are the same kind but may be more
  frequent.
- Soniox and Deepgram were not recorded again; they go through the same rule.
- Text inserted before the live word still moves that word to the right at
  once (a short line, or under 24 pt of words after the change). Unchanged
  from 2026-11-19.

## Provisional marks are not held

On the recording the half-second hold made the line stand still three times
for 0.4 s or longer (once without the hold): a revealed provisional `-` or `.`
made every following partial count as a rewrite of visible text. On
2026-11-21 the user chose not to hold the tail and to leave the adapter
alone, so the text Drop auto-stop watches is unchanged.

- A rewrite that begins in the last two revealed characters, or changes only
  marks and spaces up to the end of the revealed text, is shown at once.
- The hold of other rewrites is 0.35 s instead of 0.5 s. With 0.5 s one real
  rewrite on the recording still stopped the line for 0.45 s. ElevenLabs
  sends a partial about every 0.3 s, so a change that the next partial takes
  back is still never shown.

With both, the recording has as many stops of 0.4 s or longer with the hold
as without it (one, a pause of the speaker).

## Rejected

- Hiding the shortening by keeping the removed words on screen: the wing
  would show text the provider no longer has.
- Turning `no_verbatim` off: it changes the delivered transcript, not only
  the display.

2026-11-21
