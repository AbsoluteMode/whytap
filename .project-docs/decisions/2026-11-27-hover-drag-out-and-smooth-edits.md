---
id: hover-drag-out-and-smooth-edits-2026-11-27
type: decision
title: A tool is removed by throwing it out of the hover; the whole footer strip is More tools; edits stay open until a click outside or a return, and grid edits animate without jumps
summary: In the island's hover drawer a lifted tile let go outside the drawer is removed (red minus, disappearing-item cursor and dimmed tile before the release, system poof after), dropping it back inside or Escape keeps it; the context menu stays as a secondary path. The footer is one full-width More tools button. After an edit the drawer closes only on a click outside, Escape, or once the pointer has left, come back and left again. The grid is a plain Layout with scale-and-fade transitions, More is mounted ahead and opens in the drawer's own transaction.
status: confirmed
tags: [island, hover, toolbox, pin, unpin, more-tools, animation, drag]
canonical_for: [hover-drag-out-removal, hover-edit-animation]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: On 2026-11-27, on build 1782 with PR #489, the maintainer asked (ORCH-TASK 39 REV 4) that removing a tool not close the hover by itself, that every add, remove and reorder animation be smooth, that a tool be removed by throwing its icon out of the hover as the original task said, and that More tools span the whole bottom strip (translated).
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverHitBridge.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverTileGridLayout.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandHoverDrawerMotionTests.swift
    confirmed_at: 2026-11-27
related: [2026-11-26-hover-unpin-and-more-tools.md, 2026-11-25-island-hover-reorder.md]
---

## Context

PR #489 added Remove from Hover (context menu), More tools and an edit hold.
On build 1782 the maintainer found that a removal could still close the
hover, that adding and removing stuttered, that removal should be a drag out
of the hover, and that More should be the whole bottom strip.

## Decision

- **Throw out to remove.** The press-and-drag lift from the reorder is the
  same gesture. `IslandHoverReorder.panel` is the drawer's frame, measured at
  the lift from the drawer's `.navigation` region. Outside it the floating tile
  shrinks to 0.9, dims, shows a red minus and the cursor becomes
  `NSCursor.disappearingItem`. Letting go there calls `HoverLayoutStore.unpin`
  (the order reached so far is kept), plays the system poof
  (`NSAnimationEffect.poof`, not under Reduce Motion), fades the picture in
  place and gives a haptic. Back inside before letting go keeps the tool;
  Escape (local and global key monitors, only while a tile is lifted, never
  consumed) restores the order before the lift. Settings and Soon tools do
  not lift; the context menu stays for them, for VoiceOver users and as a
  secondary path.
- **Edit hold.** `IslandHoverEditHold` has four phases: `held` (edited with the
  pointer inside), `away`, `reentered`, `free`. A drop outside starts `away`.
  Only a click outside, Escape, or leave -> return -> leave releases it.
- **More strip.** With tools to add, the footer is one button: the hovered
  tool's description or "More tools" on the left, the chevron on the right,
  the hover highlight across the strip.
- **Motion.** `IslandHoverTileGridLayout` replaces `LazyVGrid` in an always
  present `ScrollView` (a scroll view only past four rows). Added and removed
  tiles and More rows scale from 0.6 and fade. The More section is mounted
  0.45 s after the drawer appears and opens by height and opacity inside
  `withAnimation`, so the drawer and the section move together. Tile frames
  for the floating layer are kept in a plain box, not `@State`.

## Why

- Measured, not guessed (`IslandHoverDrawerMotionTests`, the real drawer
  hosted offscreen, debug build): with the lazy grid the shifted neighbours
  were already at their new cells on the first frame after a removal while
  only the last tile slid, crossing the footer; a removed tile vanished in one
  frame (`.transition(.identity)`). Opening More changed the drawer height
  outside any animation: the drawer jumped open, stayed empty for about
  150 ms and then the rows faded in, with one 30-62 ms frame for building the
  section on the click.
- Hypotheses that the measurements rejected: per-frame `@State` writes from
  the tile frame preference, the per-tile AppKit hit-target views, the tile
  frame `GeometryReader`s and the native glass backdrop each changed the
  main-thread time by less than run-to-run noise. The per-frame cost while
  tiles move is the same for a plain reorder, which the maintainer accepted.
- A drag outside the panel matches how macOS removes items from user-arranged
  containers (Dock, toolbars): the same cursor and poof. It reuses the lift,
  so a press is still a click, a drag still reorders.
- The hold must not count hover edges the edit causes: a tile vanishing under
  the pointer or the menu closing over the drawer sends an "inside" signal,
  which in #489 was read as the pointer's return, so the next tiny move out of
  the shrunk drawer closed it.

## What was tested

- `IslandHoverReorderTests`: throwing out removes and saves, the tile shows
  the outside state, coming back inside keeps it, Escape restores, the
  vanishing starts where the pointer let go, the drawer frame decides
  outside (search, footer and More count as inside; the pill area does not).
- `IslandHoverUnpinTests`: the four-phase hold with the island's real close
  gate, including the owner's case (inside signal right after a removal,
  then a leave, stays open), grid cell placement.
- `IslandHoverDrawerMotionTests` (`WHYTAP_HOVER_MOTION_DIR`): frame strips and
  timings before and after, plus a render of the three drag states.
- Not verified here: the poof and cursor in the installed app, the physical
  drag outside the island window, and Liquid Glass composited live.

## Rejected

- Double-click or right-click as the primary removal (not what the task
  agreed; kept as a secondary path).
- An edit mode with delete badges (iOS idiom, a mode on a transient hover).
- Removing on release outside the grid but inside the drawer (search and the
  footer are part of the hover; letting go there should keep the tool).
- Rasterizing the tiles to cheapen frames (would flatten native glass and
  hover feedback).
- Building More on the click with a longer fade (hides the spike, keeps it).

2026-11-27 · branch feature/hover-drag-out-remove
