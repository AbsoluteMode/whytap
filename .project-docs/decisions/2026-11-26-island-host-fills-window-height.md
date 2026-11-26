---
id: island-host-fills-window-height-2026-11-26
type: decision
title: The island's hosting view fills the height of the window AppKit created
summary: A 27.5 pt camera band made the island window request a 660.5 pt height. AppKit snapped the window to 661 pt with its top at the screen edge, and the hosting view was then sized back to 660.5 pt from the window's bottom, leaving one Retina pixel of wallpaper above the island. The host now takes the actual window height; its width and the plate's 27.5 pt height stay as before.
status: confirmed
tags: [island, geometry, notch, appkit, retina]
canonical_for: [island-host-frame]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 an external user (Mac17,8, macOS 27.2.1, Whytap 2.2.27 build 1742) reported a one-physical-pixel gap between the top screen edge and the island and sent a geometry probe; the orchestrator relayed it as ORCH-TASK 34 and asked to fix it with a test on those numbers.
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandPanel.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandHostFillsWindowTests.swift
    confirmed_at: 2026-11-26
related: [2026-11-22-island-beside-system-island.md]
---

# The island's hosting view fills the window height

## Context

The user's probe: screen frame 1496 x 967 pt, `visibleFrame.maxY` 939,
`safeAreaInsets.top` 27.5, auxiliary areas 939.5 to 967. The island window was
flush with the top (CG y = 0) and 661 pt tall, yet one physical pixel of
wallpaper showed above the black plate.

The island window requests the compact band plus the hover drawer, the agent
gap and the answer zone: 27.5 + 145 + 8 + 480 = 660.5 pt. AppKit snaps window
frames outward to whole points (verified with an offscreen `NSPanel`: origin
306.5 becomes 306, height 661, top still 967). `IslandPanel.apply()` then set
the hosting view to the requested size, 660.5 pt, at origin zero. A view's
origin is its bottom-left corner, and `IslandView` pins the island to the
host's top-leading corner, so the plate's top landed at 966.5.

The user's guess (plate anchored to `visibleFrame.maxY`) gives the same
number but not the mechanism: no island code reads `visibleFrame.maxY` for the
plate on a notched screen, and the plate height is the camera band, 27.5 pt.

## Decision

`IslandPanelFramePolicy.hostFrame(requestedWindowFrame:actualWindowFrame:)`
sizes the host after every `setFrame` and once at creation. Its height is the
actual window height (never less than requested), so the top-pinned plate
meets the window top, which AppKit keeps at the screen edge. The width stays
the requested width.

## Why

- The fault is the requested and actual window heights disagreeing, so the
  host follows the real window instead of a computed one.
- Width stays requested because the compact, music and agent hit zones are
  anchored to the host's right edge (`bounds.width - rightAgentZoneWidth`).
  The actual window can be up to 1 pt wider after an outward snap, which would
  move those zones without moving the leading-pinned content.
- The plate keeps the real camera band height. Rounding it to 28 pt would make
  the plate 0.5 pt taller than the hardware notch on every 27.5 pt display.
- Whole-point bands (32 pt) produce whole-point windows, so their host frame is
  bit-for-bit unchanged.

## What was tested

- `IslandHostFillsWindowTests`: the user's exact numbers reproduce the pre-fix
  966.5 top and give 967 with the fix, with the compact hit rectangle on 939.5.
  A 32 pt screen keeps the old host frame, a 37.5 pt scaled screen now meets
  its top as well, and the host never shrinks below the requested height.
- The AppKit snapping assumption is asserted on a real, never-shown `NSPanel`.

## Rejected

- Round the plate height to 28 pt: taller than the camera band, and it would
  still leave other fractional values exposed.
- Request an already whole-point window height in `IslandFrameLayout`: it
  would fix this window but not the hosting-view/window mismatch, and it
  changes frames that other surfaces (meeting nudge, Case card) align to.
- Let the host fill the whole actual window (width too): moves right-anchored
  hit zones by up to 1 pt on screens with a fractional notch edge.

Known related risk, not changed here: windows attached below the island
(meeting nudge `MeetingPillView`, Case approval card) size their hosts the same
way and may show a half-point seam on fractional bands.

2026-11-26, ORCH-TASK 34.
