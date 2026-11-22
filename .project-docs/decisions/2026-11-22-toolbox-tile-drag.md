---
id: toolbox-tile-drag-2026-11-22
type: decision
title: Toolbox tiles carry no gesture but their tap, so dragging tiles works again
summary: Build 1712 (with #400) stopped dragging Toolbox tiles onto the hover row and reordering them; the tile went back to the focus and gesture surface that coexisted with `.draggable` (plain focusable view with one tap) and its hover/press/focus feedback is observed by a passive mouse monitor instead of a press gesture.
status: confirmed
tags: [settings, toolbox, drag-and-drop, regression, accessibility]
canonical_for: [toolbox-tile-drag]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer, on installed build 1712, could no longer drag a catalog tile (Calendar) into YOUR HOVER ("why can't I drag anymore").
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Settings/ToolboxSettingsView.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/Settings/ToolboxTileInteractionTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-toolbox-tool-hotkey.md, 2026-10-18-toolbox-drag-feedback.md]
---

# Context

PR #400 changed the tile in two ways that touch gesture handling: a
`simultaneousGesture(LongPressGesture(minimumDuration: .infinity))` for the
pressed tint and `.focusable(interactions: .activate)` (button-like
activation) to keep a click from focusing it. `.draggable` sits outside the
tile, in the catalog and the hover row. After 1712 the user could not drag
tiles at all. The hover row has no capacity limit (`placeTool` accepts any
tool), so the layout was not the cause. A Button over `.draggable` already
broke dragging on macOS 15 (FB14518001); a child gesture that stays possible,
or button-like activation, takes the same mouse sequence away from the drag.

# Decision

- `ToolboxTileView` carries only `.onTapGesture` plus `.focusable()`, the
  surface that dragged fine before #400. No press gesture, no
  `focusable(interactions:)`, no Button.
- `ToolboxTilePointerTracker` provides the feedback without taking part in
  gesture recognition: while the pointer is over the tile, a local monitor
  for left mouse down/up observes and returns every event unchanged. Down sets
  pressed, up clears it; leaving the tile clears it too (a drag session
  swallows the mouse up).
- The system focus effect is off (`.focusEffectDisabled()`). The tile draws a
  2 pt accent ring around its circle when focused, unless the focus came from
  a click (the monitor sees the mouse down before AppKit moves focus), so a
  click shows no ring and Tab does.
- Selection wash, hotkey block, hover tint values (10 % / 18 %) are unchanged.

# Why

The drag is the tile's primary interaction in Toolbox; feedback must never
compete with it. A passive monitor cannot affect gesture arbitration because
it only reads events and exists only while hovered.

# What was checked

- `ToolboxTileInteractionTests`: the tile source has exactly one tap and none
  of simultaneous/high-priority gestures, Long press or Drag gestures,
  `@GestureState`, Button or `focusable(interactions:)`; catalog and hover
  tiles keep `.draggable(tool.rawValue)`; the store accepts a catalog drop on
  Add and a reorder; the tracker's press follows down/up and resets on hover
  exit; click focus has no ring, keyboard focus has it; a synthetic click still
  selects (no `.draggable` in that window).
- A real drag is not tested automatically: an attempted probe started a
  system drag session from a synthetic event that waited for the physical
  mouse and blocked the Dock until the process ended. No test may start one.
- Not checked: dragging with a real pointer in the installed app (the
  acceptance step), VoiceOver.

# Rejected

- Keeping the press gesture with a smaller slop: any child gesture can hold the
  mouse sequence.
- Dropping pressed feedback: the builder asked for full-tile hover and press.
- Testing a real drag: unsafe (see above).

2026-11-22 · branch claude/toolbox-tile-drag-fix
