---
id: live-text-stable-display-2026-11-23
type: decision
title: The live line does not show snapshots that take shown words back
summary: ElevenLabs scribe_v3_live alternates between readings of the phrase it is decoding and sends earlier, shorter states of it for a second or two; the 0.35 s hold let each one through and the words on screen disappeared and returned. A stabilizer in the recording wing now shows new words at once, leaves out snapshots that only end earlier, and shows a change of earlier words once the provider has kept it for 1.5 s.
status: confirmed
tags: [island, dictation, live-transcript, animation, elevenlabs]
canonical_for: [recording-wing-live-text-snapshot-selection]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-23 the user reported that with ElevenLabs the live text jumps from time to time during dictation, that a phrase keeps disappearing and appearing again, and gave a screen recording of it.
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/LiveTextStabilizer.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandLiveTextTickerView.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/LiveText/LiveTextStabilizerTests.swift
    confirmed_at: 2026-11-23
related: [2026-11-21-live-text-forward-only.md, 2026-11-19-live-text-rewrite-hold.md]
---

# The live line shows only snapshots that keep its words

## Context

After the rewrite hold ([2026-11-19](2026-11-19-live-text-rewrite-hold.md))
and the forward-only scroll ([2026-11-21](2026-11-21-live-text-forward-only.md))
the user still saw the line jump with ElevenLabs `scribe_v3_live`, build
2.2.26 (1723). A 15 s screen recording of 2026-11-23, read at 10 frames per
second, shows the line during the first 7 s of a take. The speech was
Russian; the words below are English stand-ins in the same order:

1. "Yeah. So, now. Yeah. And"
2. "So, now. And" for 0.6 s, then "So, right now. And in the list of r"
3. "So, now. And" again for 0.5 s, then "So, now. And in the list of requests"
4. "Yeah. So, now", then "Yeah. So, now. And in the list of requests al"
5. "So, now" for 0.8 s, then "So, now. And in"
6. "Yeah. So, now. And in the list of requests also need", steady from there.

So the provider alternates between two readings of the same phrase (with and
without the first word, a short and a full form of one word) and four of its
partials are an
earlier, shorter state. Each reading stays for 0.5 to 1.2 s. The hold waits
0.35 s and then shows the newest snapshot whatever it is, so every reading was
drawn: words left the screen and were revealed again from dust, and the start
of a short line moved by the width of the first word.

The provider's documentation (read 2026-11-23) says only that later partials
replace earlier ones. A partial carries no sequence number, time or stability
mark, so an old one cannot be recognised by anything but its text.

## Decision

`LiveTextStabilizer` stands between the provider's text and the line. It
compares each snapshot with the revealed text word by word (case and
punctuation ignored; longest common subsequence, each word matched as early
as possible) and finds the last word both have in common.

- Words of the snapshot after that word are shown at once. They replace
  whatever the line showed after it: that is the provider's live guess.
- A snapshot with nothing after that word, while the line shows more, is an
  earlier state of the phrase. It is not shown.
- Text before that word stays as the line shows it. A different beginning, a
  removed repetition or a shorter phrase is shown in one step when the
  provider's snapshots have begun with the same words for 1.5 s. A provider
  that changes its mind starts the wait again.
- Words delivered but not revealed yet are replaced freely.
- A text without a common word, an empty text, a change spanning more than
  120 words and text without spaces are shown as they arrive.

The 0.35 s hold and the forward-only layout still apply to what the
stabilizer lets through. Only the recording wing uses it: paste, Drop
auto-stop and the fallback read the provider's own text. The rule is the same
for every provider, since only the text is compared.

## Why

- The user reads the line as growing. Words that disappear and return read as
  a fault even when each step is smooth.
- An earlier state and a real removal look the same when they arrive. Time
  tells them apart: on the recording no alternate reading lasted 1.5 s, while
  a correction the provider means stays.
- New words must not wait for the beginning to settle, so the line is built
  from the shown beginning and the snapshot's end.

## What was tested

- `testTheAlternatingTakeRollsBackWithoutTheStabilizer`: the sequence above,
  with the stabilizer off, loses more than six shown characters in a frame at
  least three times.
- `testTheAlternatingTakeNeverTakesShownWordsBack`,
  `testTheAlternatingTakeNeverMovesVisibleTextBackwards`,
  `testTheAlternatingTakeEndsOnTheProvidersText`,
  `testNewWordsOfTheAlternatingTakeAreNotDelayed`.
- Order of events: `testAnEarlierShorterSnapshotIsNotShown`,
  `testAShorterPhraseTheProviderKeepsIsShownAfterTheConfirmTime`,
  `testAChangedBeginningWaitsWhileNewWordsAreShownAtOnce`,
  `testAProviderThatChangesItsMindStartsTheWaitAgain`,
  `testTheLiveWordIsReplacedAtOnce`, `testARepeatedWordAtTheLiveEdgeIsNewSpeech`,
  `testWordsNotRevealedYetAreReplacedFreely` and the pass-through cases.
- The 2026-11-21 recorded take still passes its four tests.

## Not verified

- The look in the running app.
- The provider's actual events of the 2026-11-23 take: the sequence was read
  from the screen, not from the socket. No live request was made.
- Soniox, Deepgram and OpenAI were not recorded; their appended text passes
  through unchanged.

## Consequences

- A repetition or false start that ElevenLabs removes behind the live word
  stays on screen up to 1.5 s longer than before.
- A wrong last word that the provider removes while the speaker is silent
  stays for 1.5 s.
- For that time the line can show a beginning the provider no longer has.

## Rejected

- A longer hold for every rewrite: new words in the waiting snapshots would
  not be shown and the line would stop.
- Dropping old partials in the ElevenLabs adapter: a partial has nothing to
  order it by, and auto-stop reads that text.
- Asking the provider for fewer revisions: the documentation lists no such
  parameter.

2026-11-23
