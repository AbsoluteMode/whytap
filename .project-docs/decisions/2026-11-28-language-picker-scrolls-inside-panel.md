---
id: language-picker-scrolls-inside-panel-2026-11-28
type: decision
title: Language picker flags scroll inside a fixed-height drawer
summary: The island's input and output language pickers keep one drawer height that fits the curated four-row flag grid; search results or variant lists that need more rows scroll inside a clipped viewport below the search field instead of drawing below the drawer over other windows.
status: confirmed
tags: [island, hover, language-picker, layout, scrolling]
canonical_for: [language-picker-drawer-height]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 the owner reported (orchestrator task 110, screenshot) that typing "e" in the Output Language picker drew a fourth flag row and a lone Spain flag below the glass panel, over other windows.
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandDropModeControl.swift (IslandLanguagePickerLayout.grid, languagePickerHoverPanelHeight)
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandLanguagePickerGridTests.swift
    confirmed_at: 2026-11-28
related: [2026-10-17-hover-tool-search.md, 2026-10-17-native-hover-glass.md]
---

# Language picker flags scroll inside a fixed-height drawer

## Context

The language pickers placed every flag at absolute positions computed for a
145 pt panel with at most four rows. Two things were wrong:

- The drawer is the hover band minus the 8 pt gap, so it was 137 pt, not
  145 pt. The curated grid's fourth row already ended 3 pt below it.
- Search results ignore the four-row assumption. "e" in the Output Language
  picker returns Off plus 32 languages: five rows of 26 pt targets at a 30 pt
  stride. Only three rows fit; rows four and five were drawn below the glass,
  and the AppKit hover band (which follows the same height) did not cover
  them, so visible flags were not clickable. The host window is taller than
  the drawer and nothing clipped the flags.

The lone flag on the fifth row is Galician (`gl`), which shares Spain's flag
with Spanish; a single-item last row is centred. It is a separate language,
not a duplicate entry. The small window thumbnail among the overflowed flags
was not drawn by the picker: the flags had no backdrop, so the window
underneath showed through.

## Decision

- `IslandLanguagePickerLayout.drawerHeight` (145 pt) is the drawer the
  curated grid needs; the pickers' band is that plus the gap
  (`languagePickerHoverPanelHeight`, 153 pt) and stays fixed while typing.
- `IslandLanguagePickerLayout.grid` returns the search field, the chips
  pinned beside it (the Auto/Off chip of the curated grid), the scrolling
  chips, a viewport from just below the search field to the drawer's bottom,
  and the content height. The view draws the scrolling chips in a vertical
  `ScrollView` clipped to that viewport; scrolling is disabled when the
  content fits. A new result set starts at the top.

## Why

The drawer keeps one size per mode, like History, Tasks and Calendar, and
the tool grid, which caps at four rows and scrolls. Resizing with every
keystroke would move the drawer's bottom edge and the AppKit hit band under
the pointer and could close the hover. A clipped scroll view makes drawing
and hit-testing agree: only visible flags receive clicks. The partly visible
fourth search row shows that more results exist.

## What was tested

Layout tests at four island widths cover the curated grids (input and
output) fitting without scrolling, a catalog-sized grid and a short pane
scrolling, row counts and scrolling for "", "e", "a", "span" and a
no-match query, the three-row scroll boundary, variants, the band minus gap
equalling the drawer, unique language IDs in every result and the Galician
case. The live island was not exercised by the worker.

## Rejected

- Grow the drawer with the result rows: jumps per keystroke and can exceed
  the visible frame on short displays.
- Clip without scrolling: hides results that cannot be reached.
- Shrink search targets to fit five rows: smaller click targets, and longer
  queries still overflow.

2026-11-28, PR: see fix/output-language-picker-overflow.
