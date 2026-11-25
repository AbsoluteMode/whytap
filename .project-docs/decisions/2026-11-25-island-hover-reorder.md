---
id: island-hover-reorder-2026-11-25
type: decision
title: Tools are reordered by holding a tile in the island's hover; Settings keeps only switches
summary: In the island's hover drawer a tool tile held for 0.35 s lifts, the other tiles make way as it is dragged, and letting go keeps the order in HoverLayoutStore, the same layout Settings -> Features -> Hover lists. A short press is still a click; Settings never lifts; the lifted tool holds the drawer open; letting go far outside the tools restores the earlier order, and a layout change from elsewhere (Settings Sync) ends the drag without undoing it. Drag-and-drop is removed from the Settings Hover list, which keeps the switches and Move Up/Down for keyboard and VoiceOver.
status: confirmed
tags: [island, hover, toolbox, reorder, settings, features]
canonical_for: [island-hover-reorder]
verified_at: 2026-11-25
sources:
  - type: user-confirmed
    reference: On 2026-11-25, on build 1757, the maintainer said the reorder works but the animations are too poor, not smooth (translated; ORCH-TASK 103 REV 2).
    confirmed_at: 2026-11-25
  - type: user-confirmed
    reference: On 2026-11-24 the maintainer said he would improve the Hover itself so that a tool can be held and swapped with another in the hover, leaving on and off to the toggles (translated). On 2026-11-25, after the Settings list shipped, he said it did not drag for him, asked why Settings, and repeated that the tools should be held and dragged in the hover, since they are now switched on with toggles (translated; ORCH-TASK 103 REV 1).
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverHitBridge.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandHoverReorderTests.swift
    confirmed_at: 2026-11-25
related: []
---

## Context

[Settings -> Features -> Hover](2026-11-24-hover-notify-monitor-screens.md)
listed the island's tools with switches and let a row be dragged to change the
order. Maxim meant something else: change the order in the island itself, by
holding a tool in the hover and moving it, with the switches in Settings only
turning tools on and off. In build 1753 the Settings drag also did not work for
him.

The island's hover is a non-activating panel over another app. Its clicks do
not reach SwiftUI gestures; `IslandPanel.sendEvent` dispatches them through
`IslandHoverHitBridge` against measured tile frames. A drag in the island has
to live in that same dispatch.

## Decision

- **Hold to lift.** A mouse-down on a tile starts a 0.35 s timer
  (`reorderHoldDelay`). If the button is still down and the pointer has not
  left the tile, the tool lifts (`liftPressedTool`): the press stops being a
  button, the tile grows (1.14x) with a shadow, the others dim slightly and a
  light haptic is played on trackpads. A shorter press stays an ordinary click;
  leaving the tile before the timer cancels both, as before.
- **Drag over cells.** At the lift the bridge measures every tile's frame once
  by slot (`IslandHoverReorder.cells`). While the button is held, the pointer
  over a cell calls `HoverLayoutStore.placeTool` for that slot, so the tool
  takes that place at once and the others slide (tiles are identified by
  tool, animated with a spring unless Reduce Motion is on). Outside the grid
  nothing moves. Settings' cell means "last, before Settings".
  Tiles used to be identified by slot index so that replacing a tool (Case
  with another) did not fade the old tile out as a tail; identity by tool now
  carries `.transition(.identity)` for the same reason, and the source
  contract in `IslandHoverPanelControlTests` says so.
- **Let go.** The release keeps the order (it is already saved) and never
  activates the tool. Letting go more than 24 points outside the tools
  (`IslandHoverReorder.cancelsRelease`) puts the order from before the lift
  back; just past the edge still counts as a drop. Escape does the same only
  when the island already has keyboard focus: in the ordinary tools drawer it
  is not key, and a drag must not take focus from the person's app or swallow
  their Escape. Hiding the island, the drawer closing for another reason, or
  the next press end the drag with the order reached.
- **A layout changed from elsewhere ends the drag.** While a tool is lifted
  the bridge watches `HoverLayoutStore.slots`; a change the drag did not
  write (Settings Sync reloading the defaults, Settings, the MCP tool) ends
  the drag as it is. A later move never re-inserts a tool sync removed, and a
  cancel restores the old order only while the same tools are in the island
  (`restoredOrder`), so it never undoes a synced addition or removal.
- **The drawer stays.** A lifted tool counts as an interaction that holds the
  hover drawer (`interactionHeld` and `isHoverExpanded` in `IslandView`), so
  passing outside the island mid-drag does not fold it; the window keeps the
  mouse sequence it owns.
- **What cannot lift:** Settings (always last), coming-soon tiles, search
  results.
- **Settings -> Features -> Hover** loses drag-and-drop (handle, drop targets,
  `HoverToolDragModel`, the internal drag type). It keeps the list in the
  island's order, the switches, the shortcut editor, and Move Up / Move Down /
  Move to Top in the context menu and VoiceOver actions, which are the way to
  reorder without a pointer. The screen's text says the order is changed by
  holding a tool in the island.

- **Smooth motion (REV 2).** On 1757 the tile jumped from cell to cell, the
  whole island redrew on each change and every intermediate order was written
  to defaults. Now the lifted tool is drawn by a floating layer above the grid
  (`IslandHoverFloatingTile`, outside the glass container so its glass never
  melts into the tiles it passes): it starts exactly over its cell (frames
  reported by `IslandHoverTileFramesKey`), follows the pointer frame by frame
  with no animation lag, and rises with a soft spring (1.1x, shadow). Its cell
  stays as an empty place that slides with the neighbours (spring 0.32 s,
  damping 0.86). On release the tile lands in its cell (spring 0.34 s, damping
  0.9) from where the pointer let go; on cancel it flies back the same way
  while the order returns. Only the floating tile observes the pointer's
  travel (`IslandHoverReorderMotion`), so a pointer move redraws one tile, not
  the island. Intermediate orders are not saved; the order is written once on
  release (`placeTool(..., persist: false)`, `saveLayout()`). Reduce Motion
  drops the springs.

## Why

- It is what Maxim asked for: the order is a property of the island, so it is
  changed where it is seen; Settings only decides what is in it.
- Measuring the cells once and mapping "pointer over cell i" to "tool at
  place i" is idempotent. A tile sliding under the pointer during the
  animation cannot send the tool back, which a per-tile "entered" rule could.
- The window-level dispatch is the only layer that reliably receives the
  island's mouse events; a SwiftUI `onDrag`/`DragGesture` would miss the first
  mouse in this inactive overlay.
- A hold delay keeps every existing click unchanged.
- Settings' drag in 1753 most likely failed because its drag type was
  declared with `UTType(exportedAs:)` without a matching
  `UTExportedTypeDeclarations` entry in the app's Info.plist, so the drop
  targets never accepted it. Fixing it would have kept two ways to drag the
  same order; removing it is simpler and matches the decision above.

## What we tested

`IslandHoverReorderTests` drives the bridge as the window does, on an
offscreen window that is never shown, with an isolated `HoverLayoutStore`: a
short click opens the tool and moves nothing; a press released before the hold
delay never lifts; leaving the tile before the hold cancels click and lift;
holding lifts after the real timer and the release opens nothing; dragging
right moves the tool live and the order survives a restart and is the list in
Settings; no flip-back while the pointer stays on a cell; dragging back and
onto Settings (Settings stays last, is not opened); leaving the grid and
releasing just past the edge keeps the last place; releasing far outside
restores the order through the same window events; a cancel restores it;
Settings Sync removing the lifted tool ends the drag and the tool stays off;
Settings Sync adding or removing another tool is kept when the drag is
cancelled; a stale lift never restores an old membership; the drawer
closing or the island hiding ends the drag; the next press is a click again;
Settings cannot lift and still opens; only tools in the island that work can
lift; the cell under the pointer is the target; a lifted tool holds the drawer
without the pointer. `HoverFeatureTests` keep the list, switches, shortcuts
and Move actions. The full `swift test` ran.

REV 2 added: the floating tile follows the pointer in SwiftUI orientation and
lands from where it was let go; pointer moves inside a cell change only the
motion model, never the bridge the island observes; nothing is written while
the tool is held; tile frames reach the grid's space through the scroll view
and the glass container; source contracts for the floating layer and the
pointer-following without animation.

Not checked in a running app (feature sessions do not launch it): the feel of
the 0.35 s hold and of the springs, measured frame rate during a real drag.

## Rejected

- Fixing the Settings drag (declaring the type) and keeping both: two places
  to drag one order, and Maxim asked for the island.
- A drag that starts immediately on movement: it would turn a slightly moving
  click into a reorder and break every existing tile click.
- Per-tile "entered" targets with a last-target guard (the Settings model):
  in a grid, animated tiles pass under the pointer; fixed cells cannot flip.
- A global Escape for the drag: a passive monitor would also send Escape to
  the person's app (closing its dialog, say); an active tap that swallows it
  would be a second input filter for a rare need. Release outside is the
  pointer's own cancel.
- Animating the grid tile itself from cell to cell (1757): it can only jump
  between cells, so it never follows the hand.
- Saving every intermediate order: defaults observers and Settings Sync see a
  burst of writes for one gesture.
- Removing a tool by dragging it out of the island: on and off stay with the
  switches in Settings, as Maxim asked.
- Auto-scrolling a long grid while dragging: the drawer shows up to its
  scroll height; a tool beyond it is moved with Move actions in Settings.

2026-11-25, ORCH-TASK 103 REV 1; builder review (queue #557) added the sync and cancel cases; REV 2 made the motion smooth.
