---
id: drop-learning-drops-2026-11-22
type: decision
title: Liquid-glass drops right of the island answer a learned Vocab, Replace or Filler suggestion
summary: A learned suggestion shows as four liquid-glass drops in the menu bar right of the island (list icon, action with +/- in a thin circle, Y, N) that bud out as a chain and retract in reverse within 0.8 s, stay 10 s with no visible timer (hover pauses), go out when the island leaves idle, and answer by click or by Control-Y / Control-N captured only while they are shown. Y and N are plain glass with only a thin coloured contour and soft glow. Learning is switched on in Settings, Other.
status: confirmed
tags: [drop, vocab, filler, replace, island, hotkeys, design]
canonical_for: [drop-learning-drops]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: ORCH-TASK 72, REV 13 and REV 14 forwarded by the orchestrator. The user approved the v7 prototype close-ups (light and dark, rest and hover) with "Yes, wire it in" (translated) and asked for no fill inside Y and N, only a contour around the whole edge with a soft glow.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DropLearning/DropLearningDropsModel.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DropLearning/DropLearningDropsView.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DropLearning/DropLearningDropsPanel.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/DropLearning/DropLearningDropsTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-drop-edit-learning.md, 2026-11-22-drop-learning-default-on.md]
---

## Context

Learning from edits after Drop finds a correction the user made in two takes
and needs one quiet question: add this term, rule or filler (or stop it)?
The user is typing at that moment, the island may become busy at any time,
and the answer must never cost the field a letter.

## Decision

- **Where:** a non-activating, never-key panel in the menu bar right of the
  island, just below the island's window level, starting under its right edge
  so the first drop buds from the island. It follows the system appearance
  (the island window is always dark). Hit testing covers only the row.
- **What:** four drops in one row: the list icon (book for Vocab, arrows for
  Replace, scissors for Filler), the action with + or - in a thin neutral
  circle ("Add “Whytap”?", "whitap → Whytap", "Stop cutting “like”?"), Y and N.
  No explanations. A full Vocab list shows the route's real limit ("Vocab full
  50/50", "≈450/450" for estimated tokens) and Y opens the Vocab editor.
- **Glass:** macOS 26 `glassEffect(.regular)` on each drop inside a
  `GlassEffectContainer` whose blend spacing (5 pt) is smaller than the gap
  between drops (7 pt): drops stand apart at rest and a drop still leaving its
  parent blends with it, which draws the bridge. macOS 14/15 use the thin
  material; Reduce Transparency an opaque fill.
- **Y and N:** plain glass inside, no fill or tint. Colour is only a 0.75 pt
  contour around the whole edge with a soft glow of the same colour (green Y,
  red N), stronger on hover and while ⌃ is held, strongest on press. Letters
  Y and N at rest; ✓ / ✕ (↗ for a full Vocab) under the pointer; symbols in
  the text colour.
- **Motion:** icon, action, Y and N bud 0.1 s apart from the drop before them
  (springs, open at 0.7 s); they retract in the reverse order in 0.6 s. Y
  swells the icon drop once with ✓ before retracting. Reduce Motion only
  fades (0.16 s).
- **Time:** 10 s of open time without a visible timer; the pointer over the
  row pauses it and leaving resumes what was left. Expiry lets the suggestion
  go (counting starts over); N declines it forever; Y saves through the same
  stores as the editors (dry run in calibration).
- **Busy island:** an active Drop or Agent phase, an open Agent answer, sleep
  or quit puts the drops out at once and lets an unanswered suggestion go.
  One suggestion at a time; a second one while drops are shown waits for the next repeat.
- **Keys:** ⌃Y and ⌃N are Carbon hot keys registered only from show to hide;
  ⌃ alone lights Y and N through a flags-changed monitor. Plain Y and N always
  reach the field. ⌃Y / ⌃N are reserved in the Hotkeys conflict check ("Suggestion
  yes / no") so no tool can take them, and the Help window lists them. If
  another app holds a combination, the drops still answer to a click.
- **Switch:** Settings, Other, Drop: "Learn from my edits", on unless the
  user switched it off ([default on](2026-11-22-drop-learning-default-on.md)).

## Why

- Control never types a character and is not a dead key in any layout, so
  ⌃Y / ⌃N cannot cost the field a letter; Option-Y types the yen sign and Option-N
  starts an n with tilde, Command-N is "New", and bare letters would eat the first letter of the
  next word. Capturing them only while the drops are shown keeps ⌃Y (yank in
  Cocoa text) for the app the rest of the time.
- A non-activating panel lets a click answer while the field keeps focus.
- Colour only on the contour keeps the glass readable over any wallpaper; the
  user found filled and tinted variants heavy.

## What we tested

Model: the chain buds one drop every 0.1 s and opens under 0.8 s; 10 s
without hover expires and retracts N, Y, action, icon; hover pauses and
resumes the rest; Y accepts once and confirms before retracting; N declines;
answers before open are ignored; ⌃ lights only while open; a second
suggestion is not shown; a busy island hides at once and lets go, but not
after Y; Reduce Motion only fades. Controller: keys captured only while the
drops are on screen, ⌃Y saves to Vocab, a busy phase releases them. Content
for all seven kinds; the full-Vocab limit. Hotkeys: ⌃Y / ⌃N conflict with a
tool; defaults have no conflict; Help rows. Offscreen renders of the real view
in light and dark (text, signs, contours, hover and ⌃ states); the glass
itself does not render offscreen and is checked in the built app.

## Rejected

- Bare Y/N, Option-Y/N, Command-Y/N: see Why.
- A visible countdown: the drops are a quiet question, not a deadline.
- Drops inside the island window: it is always dark and would not follow the
  menu bar's appearance.
- Tinted or filled Y/N (REV 12 variants A and C): heavy over bright
  wallpapers.

2026-11-22 · ORCH-TASK 72 · drops UI PR (after PR #406)
