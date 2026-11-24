---
id: click-to-copy-translation-2026-11-24
type: decision
title: A click on the Translate result copies all of it and says Copied for a second
summary: In the Translate palette (and its Toolbox pane) a click on the result copies the whole translation and shows "Copied ✓" for one second, while a drag still selects part of it. The window only watches the click from the measured frame of the result and passes every event on to the selectable text. Subtitles do not copy on click, by the user's choice.
status: confirmed
tags: [translation, subtitles, clipboard, overlay]
canonical_for: [click-to-copy-translation]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24 the user, reviewing the Translate feature clip, asked that a click on the translation copy it (relayed by the orchestrating session, task 106, with "Copied ✓" for about a second and partial mouse selection kept).
    confirmed_at: 2026-11-24
  - type: user-confirmed
    reference: The same day the user said subtitles must not copy the translation on click (relayed by the orchestrating session).
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

# A click on the Translate result copies all of it

## Context

Copying a translation took a right-click and Copy translation. The user asked
for one click: the whole translation goes to the clipboard and "Copied ✓"
shows for about a second. Selecting part of the text with the mouse must keep
working. Subtitles stay as they are: the user does not want them to copy on
click.

## Decision

- Translate palette and its Toolbox pane: a click (mouse-up within 3 pt of the
  mouse-down, single click, no Control) on the result copies
  `TextTranslationModel.result`. The window only watches the click and passes
  every event on, so the selectable text still gets drags and double clicks: a
  drag selects part, a double click selects a word (its first click has already
  copied all).
- The floating palette watches in its panel's `sendEvent` with the result's
  measured frame (`SubtitleOverlayHitTargets`' `copy` target, beside × and
  Stop). The Toolbox pane sits in the Settings window and uses a local event
  monitor for the copy target only.
- "Copied ✓" is a small capsule at the result's bottom-right corner for 1 s
  (`TranslationView.copiedShownFor`). VoiceOver hears "Copied", and the result
  has a "Copy translation" accessibility action. The context menu's Copy
  translation shows it too.
- A populated result highlights on hover and while a click is pressed. It
  has a keyboard focus ring and Return copies the whole focused result.
- Subtitles: no click-to-copy; their context menu is unchanged.

## Why

- An offscreen probe showed that a SwiftUI tap gesture on `.textSelection`
  text never fires (the selection is an AppKit overlay), while every mouse
  event of a click and a drag passes through the window's `sendEvent` with no
  nested tracking loop. Watching at the window keeps selection untouched.
- One click copies all because that is what a reply needs; part of it is one
  drag and ⌘C away.

## What we tested

- `TranslationClickCopyTests`: real mouse events on the real panel off screen,
  copies to a private pasteboard. A click copies all and the badge leaves after
  a second; a drag, a double click and a Control-click copy nothing and pass
  the events on; nothing is copyable while translating; the subtitle overlay
  has no copy target and a click on it copies nothing.
- Offscreen render of the badge.
- Not tested with events: the Toolbox pane's local monitor (XCTest does not run
  the app's event queue).

## Rejected

- A SwiftUI tap gesture on the text: it does not fire on selectable text.
- Replacing the result with "Copied" for a second: the user may still be
  reading it.
- Click-to-copy in Subtitles (built first, then removed at the user's word).

2026-11-24 · PR: click-to-copy translation (this change)
