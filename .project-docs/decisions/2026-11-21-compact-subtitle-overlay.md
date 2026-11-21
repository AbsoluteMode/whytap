---
id: compact-subtitle-overlay-2026-11-21
type: decision
title: Subtitles return to the original translator's compact caption overlay
summary: The floating Subtitles window becomes the bottom-of-screen dark caption box of the standalone RealtimeTranslator (at most five lines, newest at the bottom), with only the language pair and Start/Stop added; the Toolbox pane uses the same box.
status: confirmed
tags: [translation, subtitles, design]
canonical_for: [subtitle-overlay]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user asked to remove the status line, the Original/Follow checkboxes and the "Understand what you hear" empty screen from Subtitles, called the window a huge application and asked to restore the neat window of their local translator, allowing languages to be added to it.
    confirmed_at: 2026-11-21
  - type: user-confirmed
    reference: The reference is the SubtitleView of the user's standalone RealtimeTranslator (a local example project outside this repository), read on 2026-11-21.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Translation/TranslationView.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleCaption.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Translation/TranslationTests.swift
    confirmed_at: 2026-11-21
related: [2026-10-20-translation-tools.md]
---

# Compact subtitle overlay

## Context

Subtitles opened a 440×400 pt titled window: a heading with a Text/Subtitles
switch, labelled language pickers, a "System audio only" status, Original and
Follow checkboxes, a large empty card ("Understand what you hear") and a
Copy/Start footer. The Toolbox pane repeated the same pieces. The user compared
it with the standalone RealtimeTranslator they used before, whose subtitles
were a small dark caption box at the bottom of the screen, and asked to bring
that back. Languages may be added to it; nothing else.

## Decision

- The floating Subtitles mode is a transparent borderless panel (760×190 pt,
  clamped to the screen, 72 pt above the bottom of the island's display) with
  one dark rounded box (black 60 %, 14 pt corners, soft shadow) anchored to its
  bottom, as in the original `SubtitleView`.
- The caption is the newest translated phrases as one paragraph in 20 pt
  rounded medium white, at most five lines; older words leave at the top
  (`SubtitleCaption`, head truncation), so the newest line never moves and the
  box hugs shorter text. Status text replaces it: Connecting…, Waiting for
  speech…, Translating…, or the error with an Open API & Models button.
- The only additions to the original are one row inside the box: source →
  target language and Start/Stop (Cancel while connecting or finishing), plus
  an × that closes like the old window. The row is shown while subtitles are
  not running and on hover while they run; otherwise only the caption shows.
- Removed from the view: title and mode switch, field labels, "System audio
  only" status, Original and Follow, the empty-state screen, Copy/Clear footer.
  Copy translation, Clear and Translate text remain in the box's context menu.
- Showing subtitles orders the panel front without making it key, so the video
  or call keeps keyboard focus, as the original never took focus.
- The Toolbox pane uses the same pieces: language row with Start/Stop and the
  same dark caption box, shown only when there is something to say.
- The text palette keeps its own width when the panel switches back from the
  wider overlay.

## Why

The user's reference is a tool they used daily: subtitles are glanced at over
a video or call, so the surface should be the caption itself. Everything that
is not the caption or the two choices the user approved adds size without
helping while watching. The overlay's five-line, bottom-anchored caption keeps
the reading position stable, which is why it was kept exactly.

## What was tested

- `SubtitleCaption` unit test: idle shows nothing, status texts, blank phrases
  skipped, newest eight phrases joined, an error wins.
- Window layout test: subtitles are borderless, without window shadow, sized
  and placed at the bottom centre; switching back restores the text palette's
  width, height and shadow. The panel is never put on screen.
- Relaunch test: both modes share one autosaved frame, so a quit during
  subtitles restores the 760 pt overlay frame; the first text layout still
  uses the 560 pt palette. The builder found this case on ticket #320.
- Offscreen renders (`WHYTAP_TRANSLATION_RENDER_DIR`) of the idle overlay, a
  result and the Toolbox pane while listening. They do not prove hover,
  physical focus or live provider behavior.

## Rejected

- Click-through overlay like the original: the language row and Start/Stop
  need the pointer.
- Keeping Original as an option: the user asked to remove it; the stored
  preference stays for rollback compatibility but nothing shows it.
- Always-visible controls while running: they cover the caption the user is
  reading.

2026-11-21 · branch claude/subtitle-menu-compact-725acf
