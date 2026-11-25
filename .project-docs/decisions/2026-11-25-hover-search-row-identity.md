---
id: hover-search-row-identity-2026-11-25
type: decision
title: Hover search result rows are identified by their tool, and the footer reads the same selection as the highlight
summary: The island's Search all tools list gave each row a position id (.id(index)) inside a ForEach keyed by tool. That froze the visible LazyVStack rows at their first render, so typing "tra" kept the "t" rows with the highlight on To-do while the footer and Return followed the real selection. Rows now use .id(tool), the list is its own view, the footer reads the selected index while searching, an arrow key clears the pointer's hover, and the row carries the VoiceOver selected trait.
status: confirmed
tags: [island, hover, search, swiftui, selection]
canonical_for: [hover-search-row-identity]
verified_at: 2026-11-25
sources:
  - type: user-confirmed
    reference: On 2026-11-25 the maintainer reported (ORCH-TASK 28) that with the query "tra" Up/Down and clicks changed the footer description and the activated tool, but the selected-row background stayed on the first row (To-do).
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverToolSearch.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandHoverSearchResultsListTests.swift
    confirmed_at: 2026-11-25
related: [2026-10-17-hover-tool-search.md]
---

## Context

To-do is not a result for "tra" at all: it is the first result for "t". The
whole visible list, not only its highlight, stayed at the first letter the user
typed, while `descriptionTool`, Return and clicks read the current
`searchQuery`/`selectedSearchIndex` and therefore looked right.

## Decision

- Each result row gets `.id(tool)`, the same identity as its `ForEach`, and
  `scrollTo` targets the tool. No position id inside the list.
- The list is `IslandHoverSearchResultsList`, taking the query, matches and
  selected index as plain inputs.
- While a query is active, the footer reads `selectedSearchIndex`, which a
  hovered row also sets, so the footer and the one highlight cannot disagree.
  An arrow key clears `hoveredTool`: the latest input wins.
- Scrolling to the selection uses no anchor, so a row already in view (the one
  under the pointer) does not move; an arrow key to an off-screen row scrolls
  it in.
- The selected row has the VoiceOver `isSelected` trait.

## Why

An offscreen hosting experiment with the same structure showed that with
`.id(index)` inside `ForEach(..., id: \.element)` the visible rows of the
`LazyVStack` received no updates after their first render: neither a new
query nor a new selection reached them, and only rows created later by
`scrollTo` appeared. Without the position id, or with `.id(tool)`, every
change reached the rows. The explicit id overrides the row identity the
`ForEach` provides, so the lazy stack keeps the old rows.

## What was tested

- `IslandHoverSearchResultsListTests` hosts the production list in an
  invisible, never-key window and reads the drawn highlight from a bitmap:
  "t" -> "tra", then selections 2 and 1. With `.id(index)` restored the test
  fails with the highlight stuck at row 0 (the owner's symptom); with the fix
  it passes.
- Pointer hover, clicks and real scrolling in the island panel need a live
  check in the installed app.

## Rejected

- Forcing a redraw with `.id(searchQuery)` on the list: rebuilds every row on
  each keystroke and hides the identity conflict instead of removing it.
- A separate observable selection object: the fault was row identity, not
  where the state lives.

2026-11-25 · branch fix/hover-search-selection-highlight
