---
id: island-touch-hover-paths-2026-11-22
type: decision
title: Hover-only details, small targets and Extra on a touch display
summary: During an island touch session the first tap on a History or To-do row shows what hovering shows and the next tap acts; measured island controls take touches within 36 pt; a touch display keeps the 170 pt middle so the drawer never narrows; a tap shows a Case command in full; a long press stays a right click with no new actions; Extra is off on the built-in touch OLED until checked. A pointer, and every screen without touch, keeps what it had.
status: confirmed
tags: [island, touch, macos-27, hover, case, brightness]
canonical_for: [island-touch-reveal, island-touch-hit-areas, island-touch-long-press, touch-oled-extra]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer asked to implement the touch MacBook plan items that can be checked without the hardware (hover paths, 36 pt targets, drawer width, the Case command, a long-press decision, Extra on the OLED) and to polish them once the MacBook is bought.
    confirmed_at: 2026-11-22
  - type: url
    reference: https://developer.apple.com/design/human-interface-guidelines/accessibility (macOS touch targets of at least 36 x 36 pt)
    confirmed_at: 2026-11-22
  - type: url
    reference: https://developer.apple.com/documentation/appkit/adopting-gesture-recognizers-in-your-app (touch has no hover; a long press is delivered as a secondary click)
    confirmed_at: 2026-11-22
  - type: url
    reference: https://developer.apple.com/documentation/technotes/tn3212-supporting-sidecar-touch-input (with a touch Sidecar connected every display reports touch)
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandTouch.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverHitBridge.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Case/Approval/CaseApprovalView.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Brightness/ScreenBrightnessController.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandTouchHoverPathsTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-island-touch-tap.md]
---

# Hover-only details, small targets and Extra on a touch display

## Context

A tap now opens the island on a touch display (the tap decision). Inside the
open island several things still needed a pointer: the History preview and
the To-do full-text bubble and "+" appear only on hover, the Back and
navigation buttons are smaller than Apple's 36 pt touch target, a narrower
reported camera cutout would shrink the drawer's tiles, the Case approval
shows its command on one line with the rest in a tooltip, and a long press
arrives as a right click. Extra's gamma boost was measured on mini-LED panels
only; the new MacBook has an OLED.

## Decision

All of it applies only while a touch session runs or on a screen that reports
touch; a pointer keeps exactly what it had.

- **First tap reveals, second acts.** `IslandTouchReveal` remembers one
  revealed row. During a session the first tap on a History row shows its
  preview (what hovering shows) and the next tap copies; the first tap on a
  To-do row shows its full-text bubble and "+", the next completes it. A tap
  on another row moves the reveal; the session's end forgets it.
- **36 pt hit areas.** While a session runs the measured dispatch
  (`IslandHoverHitBridge`) grows each control's hit area to 36 pt around its
  center, never beyond its visible region (`IslandTouchHitGeometry`). A touch
  on a drawn control always picks that control; between controls the
  nearest wins. Drawing does not change.
- **Drawer width.** On a touch-capable screen the capsule's middle is at
  least the synthetic 170 pt even when the reported cutout is narrower, so
  the drawer keeps 310 pt and 90 pt tiles; the capsule stays centered on the
  camera. A wider cutout is wrapped as before.
- **Case command.** On a touch-capable island screen a tap on the command
  shows the whole command with its own line breaks (up to 12 lines) and the
  card grows to fit; a second tap collapses it, and every new prompt starts
  collapsed (`CaseApprovalController.isCommandExpanded`). A pointer keeps one
  line and the tooltip.
- **Long press.** It stays the system's right click. Target windows and the
  collapsed capsule ignore it. Inside an open panel it opens the context
  menus that already exist (To-do rows, Notify history and sources); no new
  long-press actions, and every action a menu offers has a tap path or the
  same menu.
- **Extra on the OLED.** `ScreenBrightnessDisplay.isTouchOLED` (built in,
  reports touch, not every screen reporting touch) turns `supportsExtra` off,
  so the switch, the double brightness-up press and Settings never write a
  boosted table there until it is measured on the hardware.

## Why

Hover-only details must be reachable with a finger, and "first tap shows,
second acts" is the familiar touch pattern; it cannot fire by accident with a
pointer because it needs a session. Growing hit areas only during a session
avoids changing pointer precision. Keeping the drawer width is the existing
equal-width invariant: a narrower cutout would have shrunk every tile. A
tooltip never appears for a finger, and a Case approval must show what it
approves. A gamma boost on OLED raises power and burn-in risk on a panel
nobody has measured, so it waits.

## What was tested

Scenario tests: reveal state transitions with and without a session; hit
area growth, clipping and nearest-target choice; pointer tracking unchanged
without touch frames; drawer width for 90/125/150/200 pt cutouts with and
without touch; Case expansion, collapse, reset on the next prompt and card
height (touch only); Extra off for the OLED, detection including the Sidecar
case, no boost written. Island, Case and brightness groups and the full suite
pass.

## Rejected

- Expanding hit areas for the pointer too: changes ordinary Macs.
- A press-and-hold preview on History/To-do: a long press is a right click and
  would open menus instead.
- New long-press actions on the capsule: no context menu exists there and the
  system island next to it uses long press itself.
- Showing the Case command in full for everyone: the card grows for a pointer
  that already has the tooltip.
- Keeping Extra on the OLED with a lower cap: still unmeasured.

## Not verified

Whether SwiftUI tap gestures inside the island and the Case panel receive the
emulated click, the reveal and 36 pt feel, the camera cutout macOS reports,
and Extra on OLED need the MacBook (taps also via Sidecar with macOS 27.3 and
iPadOS 27).

2026-11-22, PR: island-touch-polish
