---
id: hover-drag-out-whole-tile-2026-11-28
type: decision
title: A dragged tool is removed once its whole tile has left the hover, and adding a tool updates the island in one transaction with a quick fade-in
summary: In the island's hover drawer a lifted tile is removed on release when its picture (the cell frame at the lifted 1.1 scale, following the pointer) no longer overlaps the drawer on any side, including above toward the notch and beside it; any overlap keeps it (reorder or cancel), and the remove cue shows exactly while the tile is fully out. Adding or removing a tool changes the layout, the edit hold and the released press in one animated transaction, so SwiftUI no longer flushes the island synchronously inside the click; an added tile fades in within 0.12 s while it grows from 0.85.
status: confirmed
tags: [island, hover, toolbox, pin, unpin, more-tools, animation, drag, performance]
canonical_for: [hover-drag-out-threshold, hover-add-latency]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-27, on build 1787 with PR #522, the maintainer asked (ORCH-TASK 39 REV 5) that a tool simply disappear once its icon has completely left the hover, without carrying it anywhere (translated).
    confirmed_at: 2026-11-28
  - type: user-confirmed
    reference: On 2026-11-28 the maintainer reported (ORCH-TASK 39 REV 6) that a tool added to the hover still appears with a lag and asked for a smooth, good animation (translated).
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverHitBridge.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandHoverAddTransactionTests.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandHoverAddLatencyTests.swift
    confirmed_at: 2026-11-28
related: [2026-11-27-hover-drag-out-and-smooth-edits.md, 2026-11-25-island-hover-reorder.md]
---

## Context

PR #522 (build 1787) removed a tool when the pointer was released outside the
drawer's frame, measured at the lift from the `.navigation` region (without
that frame, outside the grid plus 24 pt). The tile under the pointer could
still cover part of the drawer, and the maintainer found it unclear: the tool
should go as soon as its icon has completely left the hover (REV 5). The
maintainer also found that a tool added from More appeared with a lag
(REV 6).

## Decision

- **Whole tile out.** `IslandHoverReorder` keeps the lifted tile's cell frame
  and the press point. `tileFrame(at:)` is that frame at
  `IslandHoverReorderMotionCurve.liftedScale` (1.1, the lifted picture's size)
  around its centre, moved with the pointer. `removesRelease(at:)` is true
  when this frame has no area in common with the drawer's frame (search band,
  grid, footer and More). Every side counts, including above toward the
  notch and beside the drawer; touching the edge counts as outside. No
  target or extra distance. The red minus and the disappearing-item cursor
  show exactly while that is true; any part back over the drawer clears them
  and a release there is a reorder (over a cell) or keeps the order. Escape
  still cancels. Without the drawer's frame the grid plus 24 pt stands in for
  it; without the tile's frame the pointer decides as before.
- **One transaction per add or remove.** `IslandHoverHitBridge.editLayout`
  changes the layout, the edit hold and the released press inside the same
  `withAnimation`. `mouseUp` runs the action first and clears the press only
  if the action did not.
- **Quick fade-in.** An inserted tile (grid or More) fades in with
  `easeOut(0.12)` while it grows from 0.85 with the edit's spring. A removed
  tile still shrinks to 0.6 and fades with the spring.

## Why

- Measured in the real island (`IslandHoverAddLatencyTests`, offscreen,
  debug build): `withAnimation { store.pin }` alone takes 0.33 ms; the bridge's
  add took 13.7 ms and the release of a real click on a More row 9.2 ms. An
  animated layout change followed by a change in another transaction (the
  edit hold after the add, the press cleared before it) makes SwiftUI flush
  the first transaction synchronously inside the call: the island updated
  inside the click before its first frame. In one transaction: 0.14 ms for
  the add and 0.26 ms for the release. From the click to the end of the first
  frame went from about 23.5 ms to about 18 ms.
- The spring-driven fade from 0.6 left an added tile at about 27% opacity and
  71% size 50 ms after the click (spring response 0.32, damping 0.86): it
  looked late even when the frame came on time. With the 0.12 s ease-out fade
  it is about two thirds opaque at 50 ms.
- The removal rule uses the picture the person sees, not the pointer, so the
  pointer position inside the tile does not matter.

## What was tested

- `IslandHoverReorderTests`: a tile partly outside on each side (below,
  above toward the notch, left, right, a corner) is kept although the pointer
  is outside; a tile fully outside on every side and diagonally is removed
  with no extra distance; touching the edge is outside; where the tile was
  grabbed shifts the pointer distance; the fallback without the drawer's
  frame; the cue appears the moment the whole tile is out and goes when a
  sliver returns; the earlier REV 4 cases. These cases fail with the
  pointer-only rule.
- `IslandHoverAddTransactionTests` counts body evaluations of a view
  observing the store and the bridge: none happen inside `pin`, `unpin` or
  the release of a click on a More row. The control case (mixed
  transactions) shows the flush. The three cases fail with the old order.
- Rejected hypotheses, measured: layout write and persistence (0.13 ms),
  `objectWillChange` of either object alone (0.06 ms), hit snapshots
  (0.11 ms), the Reduce Motion lookup (under 0.01 ms), PDF icon rasterization
  (about 2-3 ms on first draw, 0.15 ms after).
- Remaining: the first frame with a new tile costs about 17 ms against
  8.5 ms for a reorder (creating the tile's views); not changed here.

## Rejected

- A drop target or extra distance beyond the drawer: the maintainer asked for
  none.
- The pointer position as the rule: the tile can still cover the drawer.
- Deferring the layout write to the next run-loop turn: adds latency instead
  of removing the flush.

2026-11-28 · branch feature/hover-drag-out-threshold
