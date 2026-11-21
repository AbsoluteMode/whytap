---
id: island-beside-system-island-2026-11-22
type: decision
title: The island moves beside the system Dynamic Island on a touch MacBook Pro
summary: On a built-in touch display (MacBook Pro with PROLED XDR Display, macOS 27) Whytap's capsule keeps its external-monitor shape and sits right of a band reserved for the system Dynamic Island; notification cards go left of that band. Every other Mac keeps the capsule around the camera. Settings -> Other -> Island position offers Automatic, Beside the camera and Around the camera.
status: confirmed
tags: [island, touch, dynamic-island, macos-27, layout]
canonical_for: [island-system-island-placement, island-touch-display-detection]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer read the touch MacBook research (orchestrator task 65) and asked to implement everything that can be checked without the new MacBook, keeping ordinary Macs unchanged, starting with the coexistence mode.
    confirmed_at: 2026-11-22
  - type: url
    reference: https://support.apple.com/en-by/guide/macbook-pro-proled-xdr/aside/glos4np8jx5q/2026/mac/27 (Dynamic Island shows Live Activities, calls, media and the orange and green privacy indicators)
    confirmed_at: 2026-11-22
  - type: url
    reference: https://developer.apple.com/documentation/appkit/nsscreen/touchcapabilities-swift.property ; https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support (touch Sidecar makes every display report touch)
    confirmed_at: 2026-11-22
  - type: url
    reference: https://developer.apple.com/design/human-interface-guidelines/layout (avoid content behind the camera housing)
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandSystemIsland.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandFrameLayout.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandScreenResolver.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandSystemIslandTests.swift
    confirmed_at: 2026-11-22
related: []
---

# The island moves beside the system Dynamic Island on a touch MacBook Pro

## Context

The MacBook Pro with PROLED XDR Display (2026-10-28, macOS 27) replaces the
notch with a system Dynamic Island. macOS shows Live Activities, calls, media,
AirDrop, Spotlight and Siri there, and the orange and green microphone and
camera indicators. A tap expands it and a swipe over it invokes Siri. Whytap's
black capsule (`.screenSaver` level, wrapped around the camera) would cover all
of that, including the privacy indicator, and would contradict Apple's layout
guidance. Apple publishes neither the island's size nor what `safeAreaInsets`
and `auxiliaryTopLeft/RightArea` report on that display. Nobody on the team has
the hardware yet.

## Decision

- `NSScreen.touchCapabilities` (macOS 27, read through its selector because the
  project builds with the macOS 26 SDK) plus `CGDisplayIsBuiltin` identify the
  touch MacBook's own display. Any non-zero mask counts as touch; the
  selector is absent before macOS 27, so every older Mac reads false.
- Automatic places the island beside the system island only on that display.
  When more than one screen reports touch and all of them do, the report is
  treated as Apple's Sidecar caveat and nothing changes.
- Beside the system island, the capsule keeps the external-monitor shape
  (70 + 170 + 70 = 310 pt) so the drawer, tiles, music strip and every hit zone
  keep their width and code paths. It sits `systemIslandGap` (8 pt) right of a
  band centered on the reported cutout, or on the screen's middle without one,
  at least 260 pt wide and never narrower than the reported cutout. On a narrow
  scaled screen the widest agent face stays on screen first.
- Notification cards go left of that band instead of left of the capsule.
- A built-in touch display that reports no notch is ranked before the primary
  display (not under the Sidecar caveat).
- Settings -> Other -> Display -> Island position: Automatic (default), Beside
  the camera (also a preview on a notched Mac) and Around the camera (the
  earlier layout). The choice is per Mac: backed up, not synced.
- The reserved width can be calibrated without UI through the
  `sidekey.dynamicIsland.systemIslandReservedWidth` default (120-600 pt).

## Why

A capsule that keeps its full width beside the system island changes one
origin and nothing else in the island: the 2026-10-17 rule that the drawer and
the compact island share one width still holds, and no hover, hit-testing or
music code changes. Keeping the band wider than any cutout leaves room for
compact Live Activities, which grow beyond the camera on both sides. Detecting
the display instead of a model identifier works for any later touch Mac, and
the Sidecar rule keeps the team's test setup (a notched Mac with a touch iPad)
from moving the island.

## What was tested

- Scenario tests for a notched Mac, an external monitor and a notched Mac with
  a touch Sidecar: every frame (capsule, host, agent host, notification slot
  and panel, meeting nudge, middle gap) equals the earlier math.
- Hypothetical touch displays reporting a 172, 125 or 90 pt cutout, or no
  camera housing: the capsule never intersects the band, tiles stay 90 pt, the
  notification panel ends at the band and the widest agent face fits a 1512 pt
  screen; a 1024 pt scaled screen keeps the face on screen.
- Offscreen schematic renders of eight placements (no windows).
- On this Mac (macOS 27.2, notched 16") `touchCapabilities` exists and reads 0.

## Rejected

- A 140 pt capsule beside the island with a drawer wider than the capsule:
  breaks the equal-width rule and every hit zone for a layout nobody has seen.
- Moving the island left of the camera: the agent wing grows right, over the
  system island and its microphone indicator during dictation.
- Detecting by model identifier: unknown for future models, needs updates.
- Leaving the capsule over the camera: hides the privacy indicator and system
  controls.

## Not verified

What macOS reports for the cutout, whether the system island draws above
`.screenSaver` windows, how wide compact Live Activities grow and whether
taps reach a window next to the island need the real MacBook.

2026-11-22, PR: island-beside-system-island
