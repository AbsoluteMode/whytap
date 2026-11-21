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
related: [2026-10-20-translation-tools.md, 2026-11-21-subtitle-phrase-pairs.md]
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
- (Superseded for the caption's content by
  [subtitle phrase pairs](2026-11-21-subtitle-phrase-pairs.md): the box now
  shows original/translation pairs; size, placement and controls are kept.)
  The caption is the newest translated phrases as one paragraph in 20 pt
  rounded medium white, at most five lines; older words leave at the top
  (`SubtitleCaption`, head truncation), so the newest line never moves and the
  box height hugs shorter text while its width spans the panel, exactly as
  the original box did (its text frame takes the full width); a box whose width
  followed each phrase would jump left and right while reading. Status text replaces it: Connecting…, Waiting for
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
  wider overlay. Both modes share one autosaved frame, so that frame says
  nothing about the palette: its width is stored separately
  (`sidekey.translation.textPaletteWidth`, written when the user resizes the
  palette) and every text layout uses it (560 pt by default). On the first
  launch of this version the key is absent and the shared frame was written by
  the previous version: its width is kept unless the frame is a subtitles
  window (old ≥ 340 pt tall, or this overlay's 190 pt), then stored at once,
  so the guess happens only that one time.

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
- Relaunch tests: a quit during subtitles restores the overlay frame (420,
  680 and 760 pt: resized or clamped by the screen); the first text layout
  still uses the palette width. A palette width the user chose survives
  subtitles and relaunch. The builder found the 760 pt case on ticket #320 and
  the 680 pt case on ticket #322, which rejected a width-based guess.
- Update test: a 620×140 palette frame saved by the previous version stays
  620 pt; the previous version's 700×400 subtitles window gives 560 pt; both
  are stored once (ticket #327).
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
