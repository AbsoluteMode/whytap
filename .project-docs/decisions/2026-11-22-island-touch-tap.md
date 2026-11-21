---
id: island-touch-tap-2026-11-22
type: decision
title: A tap opens the island on a touch display
summary: On a screen that reports touch, transparent target windows cover the visible island surfaces while the island window ignores the mouse. A tap on the capsule opens the drawer, a tap on an agent surface is delivered through the island's measured dispatch, and a touch session keeps the island taking events until a tap lands outside, the pointer moves or eight seconds pass. Screens without touch never get a target.
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

- On a screen whose `touchCapabilities` reports touch, while the island window
  ignores the mouse and is shown, one transparent `IslandTouchTargetPanel` per
  visible surface (the capsule unless idle-hidden, the agent wing, the answer
  card) sits above it. Its view overrides `mouseDown`, which AppKit emulates
  for a finger tap.
- A tap starts an `IslandTouchSession`: the island window stops ignoring the
  mouse and the targets leave. A tap on the collapsed capsule opens the drawer
  (the same programmatic expansion as a tool hotkey, without its four-second
  collapse); a tap on another surface is replayed as a click through the
  island's `sendEvent`, the measured dispatch real clicks use.
- The session ends on a tap over the island window's transparent area (that
  tap is consumed, like a tap outside an open menu), on real pointer movement,
  when the drawer it opened closes for another reason, when the island hides,
  or after eight seconds without a tap inside. A drawer the session opened
  closes with it.
- A pointer reaching a target (trackpad on the same Mac, or any Mac with a
  touch Sidecar connected) ends the session and hands the island back to the
  pointer rules at once, so hover keeps working.
- A long press arrives as a right click and does nothing on the island.
- Screens that report no touch never get a target window, and without a
  session every routing decision is the earlier one.

## Why

Gesture recognizers are the only native path for touches, but they are
gathered by hit-testing, and a window that ignores the mouse is not
hit-tested. Small target windows over visible content claim exactly what has
something to tap, keep the transparent window click-through, and reuse the
emulated click instead of adding a parallel touch path. Replaying into
`sendEvent` keeps one dispatch for clicks and taps; if a replay ever misses,
the session already lets the next tap through.

## What was tested

- Pure routing: no targets for a screen without touch in every state, the
  pointer decision unchanged without a session, targets only while the island
  ignores the mouse, none over an idle-hidden capsule, tap actions, the
  transparent-area rule and the session clock.
- Target windows created without being shown: a tap reports its screen point,
  a retired target reports nothing, pointer entry hands the island back, a
  right click does nothing.
- Island test groups (195 tests) pass.

## Rejected

- Gesture recognizers inside the island window: not reached while the window
  ignores the mouse.
- Keeping the island window always claimed on touch screens: its transparent
  area would eat every tap near the top of the screen.
- Waking an idle-hidden capsule by tap: an invisible target would eat taps on
  the menu bar under it; hotkeys and the pointer still wake it.

## Not verified

Whether a touch reaches a `.screenSaver` non-activating panel, whether the
emulated click reaches it the same way a mouse click does and how the replay
behaves on real hardware need the MacBook or Sidecar with macOS 27.3 and
iPadOS 27 (island shown on the iPad display).

2026-11-22, PR: https://github.com/AbsoluteMode/whytap/pull/396
