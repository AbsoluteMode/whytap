---
id: subtitle-steady-overlay-2026-11-23
type: decision
title: A steady subtitle overlay with a clickable Stop and a blurred background
summary: While Subtitles run, the overlay box has one fixed size and a fixed column split. The live pair settles in place under the identity the committed pair keeps, its original shows only up to its first sentence end, and older lines leave at the top a line at a time behind a short fade. The controls cover the top of the caption on hover instead of resizing it, so Stop and × never move. The panel's hosting view accepts the first click, and the box blurs what is under it.
status: confirmed
tags: [translation, subtitles, overlay, ui]
canonical_for: [subtitle-steady-overlay]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On installed build 1723 the user reported, relayed by the orchestrating session, that the Stop button of the running Subtitles overlay could not be clicked and that the text jumped too fast. Lines appeared and vanished, so it was hard to read and to find one's place; the standalone RealtimeTranslator had no such problem.
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: The user asked for the panel's background to blur what is under it.
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Translation/TranslationView.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitlePairLayouts.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Translation/LiveSubtitleModel.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleSteadyOverlayTests.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleSpeechPairer.swift
    confirmed_at: 2026-11-23
related: [2026-11-21-subtitle-phrase-pairs.md, 2026-11-21-compact-subtitle-overlay.md, 2026-11-22-subtitle-audio-translate-slot.md]
---

# A steady subtitle overlay with a clickable Stop and a blurred background

## Context

The overlay showed phrase pairs in a box that changed with every update:

- its width hugged the widest pair;
- the column split was recomputed from the visible text;
- the caption's maximum height changed when the hover controls appeared;
- at most four whole pairs were shown, and an old pair left in one piece;
- the live pair had a fixed identity of its own, so when it was committed it
  vanished and came back as a new row that faded and slid in from the bottom;
- the live original showed a sliding window of its newest 90 characters,
  which moved every word on every update.

Stop sat at the box's right edge, so it moved sideways and up and down as
text arrived, about ten times a second. The panel never takes keyboard
focus, so a click on it first made it key and did not reach the button.

## RealtimeTranslator compared

The standalone RealtimeTranslator (read again on 2026-11-22, last commit
6938a3e) shows one translated text that only grows. It is bottom-anchored in
a box of fixed width, at most five lines high, with older lines clipped at
the top. Its buffer drops its oldest sentence only past 800 characters, far
above the visible lines, so nothing on screen reflows. It has no originals
and no controls on the box; its panel ignores the mouse.

Whytap keeps its pairs and controls, the user's choices, and takes the
stability rules from it.

## Decision

- **Fixed box.** While a session runs or pairs are on screen, the caption
  is the panel's full inner width and 146 pt high (108 pt after Stop, when
  the controls return above it). Idle without pairs, the box still hugs its
  controls.
- **Fixed columns.** The original always gets 38 % of the row and the
  translation the rest (`SteadyPairsLayout`), so a new pair never reflows the
  others.
- **Settling in place.** The live row shows under `LiveSubtitleModel.liveID`,
  which the next committed pair keeps, so a pair turns from dim to white
  where it is. Rows only appear at the bottom.
- **Live original.** The live row shows the heard original only up to its
  first sentence end (`SubtitleSpeechPairer.liveSourceHead`). The words after
  it belong to the next pair and appear there, so they do not move out of
  the row when it settles. The 90-character sliding window is gone.
- **Scrolling.** Up to twelve pairs are laid out bottom-anchored. The ones
  above the caption are clipped behind a short top fade, so an old pair
  leaves a line at a time as new lines push it up. The motion is a 0.3 s
  ease-out; Reduce Motion turns it off.
- **Controls.** While running, the controls row covers the top of the
  caption on hover instead of resizing it, so Stop and × stay in one place.
- **First click.** The panel's hosting view accepts the first mouse
  (`FirstClickHostingView`), so Stop and × act on the click that reaches a
  non-key panel.
- **Blur.** The box draws a behind-window `NSVisualEffectView` (HUD
  material) under a 45 % black tint, instead of a flat 60 % black.

### After the build check

The build queue's check of the first version found text that still moved and
a box that still changed size. Added:

- **Shown text stays in its row.** `SubtitleSpeechPairer.showLive` records how
  much of each stream the live row showed. A pause, clause or sentence cut
  then keeps at least that much in the settled pair. Before, an original that
  ran ahead of a shorter translation lost its shown tail to the next row. A
  long translation closed at an early clause and moved shown words below.
- **Newest lines of a long column.** A column is at most
  `SteadyPairsLayout.columnCap` high (the caption below its top fade). A taller
  one shows its newest lines (`NewestLinesColumn`), and both columns then start
  at the row's top. A 500-character original without punctuation no longer
  pushes its translation out of sight.
- **One size through the whole session.** From Connecting to the end of
  Finishing the caption keeps its size (`TranslationView.overlayCaption`). The
  audio permissions link moved inside the caption. A Stop before the first
  words shows "Finishing…" instead of collapsing the box. A problem's message
  is smaller and hugs its text, so it and its button fit the 190 pt panel.
- **Narrow panels.** The panel can be resized down to 360 pt. The caption takes
  the width it is given up to 708 pt (`SteadyPairsLayout.width(proposed:)`);
  the columns still depend only on that width.

## Why

- Text that moves while it is being read cannot be read: the reader loses
  their line. Every source of movement was a layout choice, not the speech
  model's output, and the recorded session shows translations that only
  grow.
- A control that moves under the pointer cannot be clicked reliably, and a
  non-key panel needs to accept the first mouse to click at all.

## What was tested

`SubtitleSteadyOverlayTests` replays the recorded OpenAI session event by
event and checks:

- rows only appear at the bottom and leave only from the top;
- the live pair settles under the same identity without rewriting its
  translation;
- every translation on screen only grows;
- the live original stops at its first sentence end;
- a long live original is not cut at the front;
- the column split depends only on the width;
- the overlay's content view accepts the first click;
- an original far ahead of its translation, and a long translation closed at
  a clause, keep every shown word in their row (these fail without
  `showLive`);
- a long column stays within its cap with the translation at the row's top;
- the caption keeps one size in every running phase and fits a narrow panel.

Offscreen renders cover the overlay early, live and stopped, the missing
key state, silent start, Stop before any words, a long original, and a
480 pt panel, each inside a red outline of the panel's edge. Offscreen the blur has nothing under it, so only its tint shows.
Not checked: the installed app, a real pointer, and the blur over a playing
video.

## Rejected

- Keeping whole-pair removal with a slower pace: pairs would still vanish in
  one piece.
- Dropping originals to match RealtimeTranslator exactly: the user chose
  pairs.
- Ignoring the mouse like RealtimeTranslator: Whytap's box has Start, Stop,
  languages and ×.
- A separate controls bar above the box: the box would lose hover while the
  pointer moved between them.
- Bottom-aligning every row's columns: a settled pair would read from two
  different heights, and its shorter column would move up with each new line.
- Bringing back a sliding window for a long original: every word would move
  on every update.

2026-11-23 · branch claude/subtitles-stop-and-steady-text
