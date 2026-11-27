---
id: language-picker-scrolls-inside-panel-2026-11-28
type: decision
title: Language picker flags scroll inside a fixed-height drawer
summary: The island's input and output language pickers keep one drawer height that fits the curated four-row flag grid; search results or variant lists that need more rows scroll inside a clipped viewport below the search field instead of drawing below the drawer over other windows. Hovering a flag shows its English name in a capsule kept inside the drawer, and the same name is the VoiceOver label.
status: confirmed
tags: [island, hover, language-picker, layout, scrolling]
canonical_for: [language-picker-drawer-height, language-picker-name-hint]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 the owner reported (orchestrator task 110, screenshot) that typing "e" in the Output Language picker drew a fourth flag row and a lone Spain flag below the glass panel, over other windows.
    confirmed_at: 2026-11-28
  - type: user-confirmed
    reference: On 2026-11-28 the owner chose, as REV 1 of orchestrator task 110, to show the language name while the pointer is over a flag (for example Galician versus Spanish, Welsh versus English) and to keep the grid layout unchanged.
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandDropModeControl.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandLanguagePickerGridTests.swift
    confirmed_at: 2026-11-28
related: []
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

### Name hint (REV 1)

- `IslandLanguageControl.nameHint` is the language's English name;
  a curated flag that groups several languages reads "Spanish +3 more";
  Auto and Off keep their own text and show no hint. The same string is
  each chip's accessibility label.
- The hint is a small capsule in the search field's style, drawn at the
  panel level (outside the scroll view) and never hit-testable.
  `IslandLanguagePickerLayout.nameHintFrame` puts it above the chip's
  visible part, or below it when above would cover the search field, and
  clamps it inside the panel minus the edge inset; text wider than the
  panel is capped and truncated. While hovered, a scrolled chip moves its
  hint with it; a new query or a selection removes it.
- The picker has no arrow-key navigation over flags (keyboard input goes to
  the search field only), so there is no keyboard selection to label.

## Why

The drawer keeps one size per mode, like History, Tasks and Calendar, and
the tool grid, which caps at four rows and scrolls. Resizing with every
keystroke would move the drawer's bottom edge and the AppKit hit band under
the pointer and could close the hover. A clipped scroll view makes drawing
and hit-testing agree: only visible flags receive clicks. The partly visible
fourth search row shows that more results exist.

The hint follows the island's own hover language rather than a system
tooltip, which appears after a delay and is not used by other island
surfaces. English names match the owner's examples and the existing
`englishName` used for output-language prompts; the app has no localized UI
strings to follow.

## What was tested

Layout tests at four island widths cover the curated grids (input and
output) fitting without scrolling, a catalog-sized grid and a short pane
scrolling, row counts and scrolling for "", "e", "a", "span" and a
no-match query, the three-row scroll boundary, variants, the band minus gap
equalling the drawer, unique language IDs in every result and the Galician
case. Name hint tests cover Spanish/Galician and English/Welsh in the "e"
results, distinct English names across the catalog, Auto/Off, a grouped
curated flag and its variants, and placement: first row below, bottom row
above, left and right edge clamping, a chip peeking at the bottom or half
under the search field, text wider than the panel and a very short panel. The live island was not exercised by the worker.

## Rejected

- Grow the drawer with the result rows: jumps per keystroke and can exceed
  the visible frame on short displays.
- Clip without scrolling: hides results that cannot be reached.
- Shrink search targets to fit five rows: smaller click targets, and longer
  queries still overflow.
- System `.help` tooltip for the name: delayed, unlike other island hints.
- Native names in the hint: do not tell an English-reading user that the
  second Spain flag is Galician.

2026-11-28, PR: see fix/output-language-picker-overflow.
