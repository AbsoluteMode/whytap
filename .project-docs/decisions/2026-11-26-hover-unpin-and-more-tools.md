---
id: hover-unpin-and-more-tools-2026-11-26
type: decision
title: Tools are removed from the island by a right-click menu and added back from a More section under the drawer's footer; the drawer stays open after either change
summary: In the island's hover drawer a right-click or Control-click on a tile opens a native menu with Remove from Hover (Settings shows a disabled "Settings always stays in Hover"); VoiceOver gets the same action. A chevron at the right of the footer ("More tools" while no tile is hovered) opens a section below the footer that lists every tool not in the island; a click adds it at the end, before Settings, and it leaves the list. After a removal, an addition or while the menu is open, the drawer is held open until a click outside it (or Escape), or until the pointer is seen over the island again and then leaves (IslandHoverEditHold).
status: confirmed
tags: [island, hover, toolbox, pin, unpin, more-tools]
canonical_for: [hover-unpin-and-more-tools]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the maintainer asked (ORCH-TASK 39) to remove a tool from the hover directly in the drawer, and for a chevron at the bottom of the drawer that shows every tool not in the hover, where a click adds it to the grid.
    confirmed_at: 2026-11-26
  - type: user-confirmed
    reference: The same day (ORCH-TASK 39 REV 1) he required that removing a tool never closes the hover; after an edit it stays until a click outside, or until the pointer comes back and leaves again, the same after adding from More and while the context menu is open.
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverMoreTools.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverHitBridge.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandPanel.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandHoverUnpinTests.swift
    confirmed_at: 2026-11-26
related: [2026-11-25-island-hover-reorder.md, 2026-11-27-hover-drag-out-and-smooth-edits.md]
---

## Context

The island's tools could be switched on and off only in Settings -> Features
-> Hover (or Toolbox). The maintainer wanted both directions in the drawer
itself: remove a tile there, and add one from the tools that are not shown.

## Decision

- **Remove:** right-click or Control-click a tile -> native menu "Remove from
  Hover". The tile goes, the neighbours slide into its place with the reorder
  spring, the layout is saved in `HoverLayoutStore` (Settings shows it at
  once). Settings' menu shows a disabled "Settings always stays in Hover".
  VoiceOver: the tile's "Remove from Hover" action.
- **More:** the footer keeps the hovered tool's description on the left and a
  chevron on the right. With nothing hovered the chevron reads "More tools".
  It opens a section **below** the footer: the tools not in the island, in
  catalog order, three per row, up to three visible rows, then scrolling.
  A click (or "Add to Hover" in its right-click menu) adds the tool at the end
  of the island, before Settings, and the grid scrolls to it when it
  overflows. The chevron is hidden when every tool is already in the island;
  if the last one was added while the section is open, it says "Every tool is
  in Hover." and still closes there. Typing in search closes the section;
  closing the drawer collapses it.
- **Drawer stays open (REV 1):** `IslandHoverEditHold` (in
  `IslandHoverHitBridge.holdsDrawer`): `edited()` after a removal, an addition,
  the menu opening and the menu closing -> `held`; the pointer seen over the
  island or the drawer's final frame -> `reentered`; leaving then -> `free`
  and the normal hover exit applies. A click outside or Escape closes the
  drawer at once through its explicit dismissal (`dismissAfterEdit` ->
  `dismissals` -> `IslandView.dismissHoverMenu`), even with the pointer still
  over the pill or the drawer; Escape typed into another Whytap window
  (Settings) is passed on to that window. Closing the drawer for another
  reason releases the hold too.
- **A tool whose own action is off** (Calendar configured as Soon) keeps its
  click disabled but can still be removed: a disabled hit target still reports
  its frame, marked inactive; clicks and drags skip it and only
  `contextMenuTarget` sees it, the same split as the switches in Settings.

## Why

- A context menu is how macOS removes an item from a user-arranged container
  (Dock "Remove from Dock", Finder sidebar "Remove from Sidebar"). An edit
  mode with delete badges is an iOS idiom, adds a mode to a transient hover
  and would compete with the press-and-drag reorder that a press already
  means. Dragging a tile out to remove it was rejected: a release far outside
  the tools already means "cancel the reorder".
- The menu is found geometrically in `IslandPanel.sendEvent`, like every
  click in this non-activating panel: the island is not key, so the SwiftUI
  bridge does not reliably see a first click.
- Adding at the end, before Settings, is what the Settings switch does, keeps
  every other tile in place (no surprise shifts) and has no "free slot" to
  look for: the layout is a list without holes. Tool shortcuts are bound to
  tools (2026-10-19 feature hotkeys), so neither removal nor addition moves a
  binding.
- The section opens below the footer so the chevron stays under the pointer:
  a second click closes it without moving the mouse.
- The hold: removing a tile can shrink the grid by a row, adding one can grow
  or shrink the grid and the section, and the menu takes the pointer to
  another window. In each case the pointer can be outside the new hover zone
  without the person leaving, and the ordinary rule would close the drawer
  under it. Requiring the pointer to come back first means a stale leave
  never closes it; the person still has two plain ways out.

## What was tested

- `IslandHoverUnpinTests`: the hold's state machine with the island's real
  close gate (`IslandView.mouseHoldsDrawer`): leave without coming back stays
  open; click outside closes; come back then leave closes; a second edit holds
  again; drawer close releases. Menu items for a tile, Settings and a More row;
  removal through the menu item while the menu is "open"; More row and
  chevron clicks through the window-level dispatch in an offscreen window;
  no menu or removal during a drag; band height with the section; a removed
  tool keeps its shortcut, search and Settings state.
- `HoverLayoutStoreTests`: pin/unpin, persistence, Settings locked, empty and
  full states.
- Builder review (ticket 618) found two gaps, now covered by tests: Escape
  after an edit only dropped the hold, so with the pointer over the drawer the
  gate kept it open; and a Soon Calendar tile had no menu because disabled
  targets were never registered.
- Not verified here: the live menu in the installed island, hover and click
  feel, and Liquid Glass rendering of the section (offscreen render only).

## Rejected

- Edit mode with "−" badges (iOS idiom; conflicts with press-and-drag).
- Drag out to remove (already means cancel).
- Inserting at the "first free slot" (there are no holes) or at the front
  (shifts every tile).
- Section above the footer (the chevron would move away from the pointer).
- SwiftUI `.contextMenu` on the tile (first click is not delivered in the
  non-key panel).

2026-11-26 · branch feature/hover-unpin-more
