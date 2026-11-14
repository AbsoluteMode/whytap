---
id: live-text-sand-2026-11-13
type: decision
title: The recording wing paces the live transcript and gathers each character from dust
summary: Live text in the island's right wing was shown as the provider delivered it, in jumps. The wing now reveals it at the speaker's rate with a 1.4 s limit on how old shown text may be, and draws each new character gathering from dust that flies in ahead of the line. Display only, the same for every provider.
status: confirmed
tags: [island, dictation, live-transcript, animation, drop, agent-voice]
canonical_for: [recording-wing-live-text]
verified_at: 2026-11-13
sources:
  - type: user-confirmed
    reference: On 2026-11-13 the user asked for the live text to come out evenly instead of in jumps, never showing text that is seconds old, chose the dust effect from a reference, rejected a prototype whose line moved and stopped, approved the even-line prototype, and asked that it work for every provider.
    confirmed_at: 2026-11-13
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/LiveTextTicker.swift
    confirmed_at: 2026-11-13
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandLiveTextTickerView.swift
    confirmed_at: 2026-11-13
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandAgentWingView.swift
    confirmed_at: 2026-11-13
  - type: repository
    reference: Tests/SidekeyTests/LiveText/LiveTextTickerTests.swift
    confirmed_at: 2026-11-13
related: [2026-11-12-drop-auto-stop-local-rule-only.md]
---

# Paced live text with gathering characters

## Context

The recording face of the right wing (`IslandAgentWingView`, Drop and agent
voice) showed the provider's live transcript in a `Text` as each update
arrived. Providers deliver in batches, so the line jumped and stopped. The
user wanted an even line, text that is never stale, and characters that
gather from dust.

## Decision

- `LiveTextPacer` decides how many characters are shown. It moves at the
  speaker's rate (text delivered over the last 4 s), keeps a reserve of about
  three quarters of the usual gap between batches to spend while waiting for
  the next one, and brings the reserve back to target over 1.5 s. Speed
  changes are eased over 0.25 s.
- **No character waits longer than 1.4 s after it was delivered**
  (`LiveTextPacer.lagCap`). Every batch has that deadline and the pacer goes
  at least as fast as the nearest one needs; text already past its deadline
  (a stalled main thread) is shown at once and solid, without gathering:
  it is already late. Being current comes before being smooth.
- `LiveTextTicker` records when each character appeared. The view draws a
  character as 14 grains that start up to 86 pt ahead of it, scattered over
  the wing's height, and land inside it over 0.35 s while the glyph fades in.
- A character the provider rewrites gathers again in place. A rewrite that
  touches more than 12 visible characters (an earlier insertion shifts the
  line) is swapped without the effect.
- A face rebuilt mid-take shows its text at once; only new words are paced.
- With Reduce Motion the previous `Text` is used unchanged.
- Text in a right-to-left script (Arabic, Hebrew and others), with explicit
  direction controls, or in a script whose letters join or reorder across
  characters (Indic, Tibetan, Myanmar, Khmer, Mongolian) also uses the plain
  `Text` (`LiveTextTicker.canDrawPerCharacter`). Drawn one character at a
  time, left to right, it would lose its joining and its order.
- Display only. Pasted text, auto-stop, the face width and every provider
  path read the provider's text as before. The wing sees only a string, so
  the behaviour is the same for Soniox, Deepgram, ElevenLabs and a server.

## Why

- The gap between batches, not the amount of text, is what makes the line
  stop. A reserve sized from the observed gap removes the stops with the
  least delay each provider allows.
- A fixed delay would be too long for a fast provider and too short for a
  slow one.
- Grain positions are derived from the character's index, so there is no
  particle state to keep or leak.

## What was tested

- `LiveTextTickerTests`: with batches every 0.2 to 0.8 s the line never stops
  and never exceeds 1.6 times speech rate; uneven batches; no character older
  than the cap at 9, 15 and 26 characters per second with batches up to 2.5 s
  apart; a 3.5 s provider pause; the last words after speech ends; shorter
  text; a short and a long main-thread stall; rewrites; rebuilt face;
  characters revealed past their deadline are solid on the same frame, on-time
  ones still gather; which scripts are drawn per character.
- Offscreen renders: nothing before the first character, grains while
  gathering, a long line keeps its tail at the right edge inside the wing,
  and after a 3 s stall the caught-up line is drawn on the first frame.
- Build review (queue ticket 212) found both the overdue-text and the
  right-to-left problems; this is the fix.

## Not verified

- The look and the frame rate in the running app: feature sessions do not
  launch it. The browser prototype the user approved used the same rules.
- Real batch intervals of each provider. With batches further apart than
  about 1 s the line still pauses, because the cap wins.
- Character advances are measured one by one, without kerning.

## Rejected

- Catching up at `backlog / delay` only: the line raced after each batch and
  stopped until the next (the first prototype, rejected by the user).
- Sampling real glyph pixels for grain targets: at 12 pt it cannot be told
  from random points inside the glyph's box.
- Pacing the text in the store: the pasted text and auto-stop must keep the
  provider's own timing.
- Shaping the whole line with CoreText and animating its glyph runs for
  right-to-left and joined scripts: much more code for scripts the user does
  not dictate in; the plain line shows them correctly.
