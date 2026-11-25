---
id: subtitle-overlay-move-resize-scroll-2026-11-25
type: decision
title: The subtitle overlay moves, resizes, remembers its place and scrolls back
summary: The Subtitles box fills its panel and the user drags it anywhere and resizes it by edges and corners (minimum 480 x 150 pt); the frame is remembered across launches and restored on its display, or at the usual place when that display is gone. A scroll over the box reads back through up to 200 pairs while new pairs arrive below without moving the text; Latest follows again. Translation speed was measured live: the model, not the app, holds the delay, and a faster engine is the owner's choice.
status: confirmed
tags: [translation, subtitles, overlay, window, scrolling, latency]
canonical_for: [subtitle-overlay-frame, subtitle-caption-scroll]
verified_at: 2026-11-25
sources:
  - type: user-confirmed
    reference: On 2026-11-25 the user asked, relayed by the orchestrating session (task 112), for a Subtitles window that can be enlarged, shrunk and moved, for scrolling back through the subtitles, and for model settings that would make the translation arrive faster.
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleOverlayFrame.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleCaptionScroll.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Translation/TranslationWindowController.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Translation/TranslationView.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleOverlayMoveResizeScrollTests.swift
    confirmed_at: 2026-11-25
related: [2026-11-21-compact-subtitle-overlay.md, 2026-11-23-subtitle-steady-overlay.md, 2026-11-23-subtitle-pairs-close-speed.md, 2026-11-22-subtitle-audio-translate-slot.md]
---

# The subtitle overlay moves, resizes, remembers its place and scrolls back

## Context

The overlay was a 760 x 190 pt transparent panel with the dark box anchored
to its bottom. The panel was already `.resizable` and movable by its
background, but none of that reached the user:

- the box hugged its content up to 708 x 146 pt, so a larger panel only grew
  the invisible transparent area;
- the transparent margin let presses through to the app below, so there was
  no edge to grab;
- every show placed the panel at the bottom centre again;
- the box showed at most twelve pairs and kept forty, with no way back.

## Decision

- **The box is the window.** It fills the panel less a 10 pt margin for its
  shadow. The margin carries a 1.2 % black fill: invisible over any picture,
  but enough for the window server to give its presses to the panel. The
  box's size depends only on the panel, never on its state. Before the first
  session the box shows its controls and one dim hint, "Start translates what
  this Mac plays.", instead of shrinking to the controls.
- **Move and resize from the panel's events.** `TranslationPanel.sendEvent`
  hands presses to `SubtitleOverlayFrameTracker`, after × / Start / Latest.
  The margin and 6 pt inside the box's edge resize (18 pt near a corner
  resizes both ways); anywhere else in the box moves it, except the language
  menus and the fix buttons. Control-click stays the context menu. The
  opposite edges stay put, the size never goes below 480 x 150 pt, a resize
  stops at its display's edges, and a move stays on the display under the
  pointer. A tracking area active while Whytap is inactive shows the resize
  cursor. The text palette keeps AppKit's own behaviour.
- **Remembered.** The frame is saved after each move or resize
  (`sidekey.translation.subtitleFrame`), never by the system moving the window:
  the display's identity (`NSScreen.sidekeyDisplayUUID`) and the frame relative
  to that display's visible frame. It is restored at the same place on the
  same display, clamped to it. When that display is gone, the saved size
  returns at the bottom centre of the island's display. Nothing saved:
  760 x 190 pt there, as before. A display without an identity goes by
  coordinates (the display holding the frame's centre or overlapping it most).
- **Scrolling back.** A scroll event over the box goes to
  `SubtitleCaptionScroll`. Following (the usual state), the newest pair stays
  at the bottom. Scrolling toward older pairs anchors the caption to the pair
  at its top; `SteadyPairsLayout` then keeps that pair at the same height
  while new pairs arrive below. A bottom fade and a Latest pill show. Latest,
  or scrolling down to the newest pair, follows again; a new session or Clear
  follows too. The caption never scrolls past the oldest pair, and one that
  fits does not scroll. A session keeps 200 pairs (about a quarter of an hour
  of speech); following lays out at least 24 and enough to fill the caption
  with its shortest rows (`SubtitleCaptionScroll.followedLimit`), scrolled
  back all of them, so every pair is in view or reachable at any size. A
  gesture toward newer pairs with the newest in view follows again. A scroll
  reads the placement at the caption's on-screen size
  (`SubtitleCaptionGeometry.current`), since SwiftUI also places the rows for
  a measurement at the ideal size; Clear, a new session and a mode change
  drop the geometry.
- **Buttons on the first click.** Open Keys & models and Open audio
  permissions act through the panel's `sendEvent`, like Stop and Latest
  (`SubtitleOverlayHitTargets.buttons`). A Control-click never acts on a
  button: it is the context menu's. Latest lightens under the pointer; the
  idle hint is 68 % white, medium weight (about 7:1 measured on the
  minimum-size render).

## Why

- The user resizes and moves what they see. With a box smaller than its
  panel, every size change was invisible.
- The overlay floats over a video in another app and is never key. The
  first-mouse bridge to SwiftUI drops presses there
  (docs/bugs/2026-09-04-island-answer-close-first-mouse.md), so a SwiftUI
  drag, or AppKit's background move behind SwiftUI's gestures, cannot be
  relied on; the window always gets the event, as for × and Stop.
- A SwiftUI `ScrollView` would replace the steady layout (fixed columns, the
  live pair settling in place, the top fade) and cannot tell "the user is
  reading" from "the user is at the bottom" on macOS 14. Anchoring to a pair
  by identity keeps the text being read still, whatever arrives or leaves.
- A system relocation (a display unplugged while open) is not the user's
  choice, so only the user's own move or resize is saved.

## Translation speed (measured 2026-11-25)

Subtitles use one OpenAI `gpt-realtime-translate` session with
`gpt-realtime-whisper` input transcription. OpenAI's reference
(developers.openai.com, translation client events) accepts only
`audio.output.language`, `audio.input.transcription` and
`audio.input.noise_reduction`: no reasoning, max tokens, prompt, cache,
turn detection or latency setting. The engine consumes 200 ms frames, which
the adapter already sends; shorter appends are buffered by the server. The
catalogue lists one snapshot and no smaller variant.

Live probe, the same 48 s synthetic lecture (12 sentences, `say`), real-time
pacing, two runs each, from the end of each spoken sentence to its complete
translation arriving:

| Engine | Median | p90 | Price |
|---|---|---|---|
| OpenAI `gpt-realtime-translate` (current) | 4.0 s / 3.6 s | 5.4 s / 4.5 s | $3.06 per audio hour |
| Soniox `stt-rt-v6` one-way translation | 0.76 s / 0.76 s | 0.82 s / 0.83 s | $0.12 per hour listed; translation text may add about $0.06 |

OpenAI streams the translation word by word but runs 3.5 to 4 s behind the
speech. Soniox gives each sentence's translation whole, about 0.8 s after the
sentence ends; its original arrives word by word as it is heard. Both
translations were correct; OpenAI's wording was slightly freer.

The app's own share, from the recorded session replayed at real speed through
the real overlay panel (`SubtitleDisplayLagProbeTests`, 45 s, 169 deltas):

- **Fixed: a delta waited for the next timer tick.** The 80 ms flush timer
  counted as a publish even when nothing changed, so `publishSoon` almost
  never published a delta at once. Now only a flush that changed the caption
  counts. Arrival to the published caption, median per 15 s: 87 / 89 / 80 ms
  on origin/main, 65 / 9 / 11 ms with the fix (the first bucket holds the
  session start). A burst still redraws once.
- **Kept: the whole-word hold** (p95 about 0.4 s, at most 0.3 s after the
  last delta): showing a fragment would put half a word on screen.

These are tens of milliseconds against the model's seconds. A faster engine
is a provider change on the owner's keys and money, left to the owner.

## What was tested

`SubtitleOverlayMoveResizeScrollTests`, real mouse and scroll events on the
panel far off every screen:

- edges, corners and the inside of the box (geometry);
- a resize keeps the opposite edges, stops at the minimum and the screen; a
  move stays on its display;
- dragging the caption moves the panel, the right edge and the top-left
  corner resize it, the minimum holds, the frame is saved; focus is not taken;
- the language menus keep their press, Start still starts, a control-click is
  the menu's, the text palette is not moved this way;
- a relaunch restores the place and size; with the display gone the saved size
  returns at the bottom of the island's display; the text palette keeps its width;
- scrolling back anchors a pair, new pairs do not move it, Latest follows
  again without moving the panel, scrolling to the newest follows, the oldest
  pair stops at the top;
- an empty or short history does not scroll; a trimmed anchor shows the
  oldest pair.

Offscreen renders: the default, minimum (480 x 150, live, stopped, missing
key) and a 1000 x 420 box, idle with the hint, and the caption scrolled back
with Latest. Not checked: the installed app with a real pointer, the
resize cursor, and a trackpad's momentum over a playing video.

## Builder review (queue #563)

The builder's offscreen probes found five groups on the first head, all fixed
and covered by tests in `SubtitleOverlayMoveResizeScrollTests`:

1. The right and top grips' inner boundaries returned a resize handle that
   resized nothing (`NSRect.contains` excludes those edges): now they resize;
   every point of three panel sizes is checked.
2. A display was known by coordinates only: after unplugging an external
   display the laptop can take its origin. Now by identity and relative place.
3. Scroll geometry: kept after Clear; a gesture toward newer pairs at the
   bottom of a grown window left Latest up; a tall caption could not reach
   pairs past the 24 laid out; a measurement pass could replace the on-screen
   placement. See Decision, scrolling back.
4. Open Keys & models and Open audio permissions did nothing on the first
   click of the inactive panel; Latest took a Control-click.
5. Latest had no hover response; the idle hint measured about 3.9:1.

## Rejected

- Keeping the transparent panel larger than the box: nothing to grab, and a
  resize nobody sees.
- `performDrag` and AppKit's background move: untestable off screen and
  dependent on SwiftUI not taking the press.
- A SwiftUI `ScrollView` with a bottom anchor: see Why.
- Shrinking the box to its controls when idle: the remembered size would be
  invisible until Start.
- A minimum of 360 pt: the controls wrap to two rows and a problem's message
  no longer fits a short box; 480 x 150 fits every state.
- Changing the speech engine here: the owner's decision (price, provider).

2026-11-25 · branch claude/subtitles-window-scroll-speed
