---
id: click-to-copy-translation-2026-11-24
type: decision
title: A click on a translation copies all of it and says Copied for a second
summary: In the Translate palette a click on the result copies the whole translation while a drag still selects part of it; in the Subtitles overlay a click on the translation column copies every completed translation, a press that moves drags the overlay. Both show "Copied ✓" for one second. Clicks are taken at the window from measured frames, as × and Stop are.
status: confirmed
tags: [translation, subtitles, clipboard, overlay]
canonical_for: [click-to-copy-translation]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24 the user, reviewing the Translate feature clip, asked that a click on the translation copy it (relayed by the orchestrating session, task 106, with "Copied ✓" for about a second, partial mouse selection kept, and the same for subtitles).
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleOverlayHitTargets.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Translation/TranslationView.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/Translation/TranslationClickCopyTests.swift
    confirmed_at: 2026-11-24
related: [2026-11-23-subtitle-pairs-close-speed.md]
---

# A click on a translation copies all of it

## Context

Copying a translation took a right-click and Copy translation. The user asked
for one click: the whole translation goes to the clipboard and "Copied ✓"
shows for about a second. Selecting part of the text with the mouse must keep
working, and subtitles should behave the same way.

## Decision

- Translate palette: a click (mouse-up within 3 pt of the mouse-down, single
  click, no Control) on the result copies `TextTranslationModel.result`. The
  panel only watches the click and passes every event on, so the selectable
  text still gets drags and double clicks: a drag selects part, a double click
  selects a word (its first click has already copied all).
- Subtitles overlay: a click on the translation column copies every completed
  translation of the session, a blank line between phrases (what Copy
  translation copies). The original's column does nothing. A press that moves
  more than 3 pt becomes a window drag (`performDrag`), since the panel is
  movable by its background. A click level with × or the session button is
  theirs: while running, the controls cover the caption's top.
- Toolbox pane: the same, passive, through a local event monitor on the
  Settings window; there a click anywhere on the stacked pairs copies.
- "Copied ✓" is a small capsule at the bottom-right of the result or caption
  for 1 s (`TranslationView.copiedShownFor`); VoiceOver hears "Copied", and the
  result and caption have a "Copy translation" accessibility action. The
  context menu's Copy translation shows it too.

## Why

- The overlay floats over a video in another, active app. SwiftUI drops that
  first click on the non-key panel (the × and Stop finding), so the click is
  taken in the panel's `sendEvent` from frames the views measure, the same
  mechanism as × and Stop.
- An offscreen probe showed that a SwiftUI tap gesture on `.textSelection`
  text never fires (the selection is an AppKit overlay), while every mouse
  event of a click and a drag passes through the window's `sendEvent` with no
  nested tracking loop. Watching at the window keeps selection untouched.
- One click copies all because that is what a reply needs; part of it is one
  drag and ⌘C away.

## What we tested

- `TranslationClickCopyTests`: real mouse events on the real panel off screen,
  copies to a private pasteboard. Click copies all and the badge leaves after
  a second; drag, double click and Control-click copy nothing and pass the
  events on; nothing is copyable while translating; the subtitle translation
  column copies, the original's column does not; a moving press drags the
  overlay instead.
- Offscreen renders of both badges.
- Not tested with events: the Toolbox pane's local monitor (XCTest does not run
  the app's event queue).

## Rejected

- A SwiftUI tap gesture on the text: it does not fire on selectable text.
- Replacing the result with "Copied" for a second: the user may still be
  reading it.
- Copying only the clicked subtitle phrase: Copy translation copies the whole
  session, and the click is its shortcut.

2026-11-24 · PR: click-to-copy translation (this change)
