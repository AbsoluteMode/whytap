---
id: island-touch-tap-2026-11-22
type: decision
title: A tap opens the island on a touch display
summary: On a screen whose touch report is trusted (not Apple's Sidecar caveat), transparent target windows cover every rendered island surface while the island window ignores the mouse. A tap on the capsule opens the drawer, any other tap is replayed through the island's measured dispatch, and the island window never claims its transparent area, so the system Dynamic Island beside it keeps its taps. A touch session only owns the drawer it opened. Screens without a trusted touch report never get a target.
status: confirmed
tags: [island, touch, macos-27, hover, input]
canonical_for: [island-touch-tap, island-touch-session]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer asked to implement the touch MacBook plan items that can be checked without the hardware; tapping the island was the second priority after the coexistence layout.
    confirmed_at: 2026-11-22
  - type: url
    reference: https://developer.apple.com/documentation/appkit/adopting-gesture-recognizers-in-your-app (touch has no hover; event monitors get no touches; AppKit emulates a single-finger tap as a click for views that handle mouseDown)
    confirmed_at: 2026-11-22
  - type: url
    reference: https://developer.apple.com/documentation/technotes/tn3216-supporting-touch-input-for-games-on-macos (mouseMoved before a tap only for games)
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandTouch.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandPanel.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandTouchTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-island-beside-system-island.md]
---

# A tap opens the island on a touch display

## Context

The island window is transparent and permanently agent-sized. It claims
mouse events only over a rendered surface under the pointer: global and local
monitors flip `ignoresMouseEvents` on `mouseMoved`, because a claimed
transparent area eats clicks. The drawer opens only from `.onHover`. On a
touch display (macOS 27) a finger has no hover and sends no `mouseMoved`
before a tap, and event monitors get no touches. A tap on the capsule
therefore fell through to whatever was under it, and the drawer could not be
opened at all.

## Decision

- The island's screen gets targets only when it reports touch and the report
  is trusted: with a touch Sidecar connected every display reports touch
  (TN3212), so then no display gets targets
  (`IslandScreenDescriptor.acceptsTouchInput`).
- While the island is shown and its window ignores the mouse, one transparent
  `IslandTouchTargetPanel` covers each rect the pointer routing would claim:
  the capsule unless idle-hidden, an open drawer's surfaces (also one a hotkey
  opened), the music strip, the notification slot, the agent wing and the
  answer card. Its view overrides `mouseDown`, which AppKit emulates for a
  finger tap. Targets are placed when the island is first shown and follow
  every display change.
- A tap on the collapsed capsule opens the drawer (the programmatic expansion
  a tool hotkey uses, without its four-second collapse) and starts an
  `IslandTouchSession`. Any other tap is replayed as a click through the
  island's `sendEvent`, the measured dispatch real clicks use. A scroll over a
  target goes to the island view under it.
- The island window itself never claims more than the pointer rules give it:
  its transparent area, which beside the system Dynamic Island covers the
  camera band, stays click-through for touches too.
- The session owns only the drawer it opened. It closes it on a second tap on
  the capsule, after eight seconds without a tap on the island, on real
  pointer movement, a display change, hide, or when the drawer closes for
  another reason. A tap elsewhere goes to whatever is there.
- A pointer reaching a target hands the island back to the pointer rules at
  once, so hover keeps working.
- A long press arrives as a right click and does nothing on a target.
- Screens without a trusted touch report never get a target window, and every
  pointer routing decision is the earlier one.

## Why

Gesture recognizers are the only native path for touches, but they are
gathered by hit-testing, and a window that ignores the mouse is not
hit-tested. Small target windows over visible content claim exactly what has
something to tap, keep the transparent window click-through, and reuse the
emulated click instead of adding a parallel touch path. Replaying into
`sendEvent` keeps one dispatch for clicks and taps. Claiming the whole
window during a session would have consumed taps on the system island next to
the capsule, so a tap outside no longer dismisses the drawer; a second tap on
the capsule or the timeout does.

## What was tested

- Pure routing: no targets for a screen without touch, trusted reports for the
  touch Mac alone, beside an external monitor, the external monitor itself and
  under a Sidecar; targets for every rendered surface including a hotkey
  drawer and the music strip; none while the island takes the pointer, while
  hidden or over an idle-hidden capsule; none over the system island band on
  the default touch geometry; tap actions and the session clock.
- Target windows created without being shown: a tap and a scroll report their
  screen point, a retired target reports nothing, pointer entry hands the
  island back, a right click does nothing.
- Island window wiring (source contract, the panel is a singleton): first
  show places targets after the island counts as shown, a display change ends
  the session before re-anchoring and refreshes the targets, the routing never
  reads the session.

## Rejected

- Gesture recognizers inside the island window: not reached while the window
  ignores the mouse.
- Keeping the island window always claimed on touch screens: its transparent
  area would eat every tap near the top of the screen.
- Claiming the whole island window during a session (the first version):
  beside the system Dynamic Island its transparent area covers the camera
  band, so a tap on the system island would have been consumed.
- Trusting every touch report: with a Sidecar connected, mouse-only displays
  would get targets.
- Waking an idle-hidden capsule by tap: an invisible target would eat taps on
  the menu bar under it; hotkeys and the pointer still wake it.

## Not verified

Whether a touch reaches a `.screenSaver` non-activating panel, whether the
emulated click and the scroll reach it the same way a mouse does, how the
replay behaves and how the windows stack with the system island need the
MacBook. Sidecar cannot show it: under its caveat no display gets targets.

2026-11-22, PR: https://github.com/AbsoluteMode/whytap/pull/396
