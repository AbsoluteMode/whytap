---
id: costs-models-popover-hover-2026-11-26
type: decision
title: One open "Models used" detail for the Costs table, checked against the real pointer
summary: Each Costs row owned its popover state, so the detail blinked and could show another row's models. One state machine for the table decides the open row from the pointer's position. Since 2026-11-27 rows are located with SwiftUI frames (NSViews inside the ScrollView report the whole window), and the detail and fill always follow the row under the pointer, closing at once off the row and detail.
status: confirmed
tags: [settings, costs, popover, hover, keyboard]
canonical_for: [costs-models-popover-hover]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the maintainer reported (ORCH-TASK 40, with a screenshot) that the pointer on the Agent row showed "Translation · Models used" beside Translation, and that the detail blinks and opens unpredictably; he likes its look.
    confirmed_at: 2026-11-26
  - type: user-confirmed
    reference: On 2026-11-27 the maintainer checked build 1782 live (screenshot) - the pointer was on Drop Fast while "Meetings · Models used" was open and Meetings highlighted - and asked that the detail and highlight always belong to the row under the pointer and that the old one close immediately when the pointer moves elsewhere.
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/AIUsageModelsHover.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/AIUsageCostsView.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/Settings/AIUsageModelsHoverTests.swift
    confirmed_at: 2026-11-26
related: [2026-10-20-feature-costs.md]
---

## Context

Costs lists used features; hovering a row opens a popover with that feature's
models, a click pins it (whole-row trigger since 2026-11-19, on the
maintainer's request). Every row kept its own `shown`, `hovered`,
`overPopover` and close task.

Causes found:

- The detail is anchored to the name with the arrow on its trailing side, so
  it opens over the row's middle, where the pointer usually rests. The row
  then reports hover exit; the detail's own hover never reports enter because
  the pointer did not move into it. After 180 ms the row closed it, the
  pointer was over the row again, it reopened: the blink.
- Rows did not know about each other. Moving from Translation to Agent set
  Agent's `shown` while Translation waited out its close delay or stayed
  held by `overPopover`; Agent got the fill but only one popover could be on
  screen, so Translation's detail remained beside Translation.
- A row covered by another row's detail kept stale hover, which later kept
  or reopened the wrong detail.

## Second report (2026-11-27)

The first fix located the pointer every 100 ms with an NSView placed behind
each row. Inside SwiftUI's ScrollView those NSViews report the row's size at
origin zero, and converting their visible rect to the screen gives the whole
window, so every row "contained" the pointer and the first match in a
dictionary won. In the live build the pointer on Drop Fast resolved to
Meetings, which stayed open and highlighted. Reproduced with a standalone
AppKit program (four rows in a ScrollView, each reporting the window's full
screen rect) and, in tests, by forcing that geometry, which fails 47 checks
of the hosting tests below. Clicks also pinned a detail against later hover,
which the maintainer does not want.

## Decision

- `AIUsageModelsHoverState` is one pure state machine for the table. Its
  input is where the pointer is: outside, on a row, or on the open detail.
  Every row's popover binding reads `open == row.id`, so a popover can only
  show its own row.
- The detail and the row fill belong to the row under the pointer. Entering
  the table from outside opens after 0.2 s; with a detail open, moving to
  another row switches at once; leaving both the open row and its detail
  closes at once. On the detail (which may cover other rows) the open row
  keeps its detail and fill.
- `AIUsageModelsHoverController` resolves the pointer from geometry: rows
  report frames through `onGeometryChange` in a named coordinate space on the
  Costs ScrollView, and one anchor NSView behind that ScrollView (outside the
  scrolled content, where NSView frames are correct) maps them to the screen,
  clipped to the visible pane. The detail is its popover window when that
  window is topmost under the pointer. Row hover callbacks, continuous hover
  on the table and the detail, an app-local mouse-moved monitor and an 80 ms
  poll while a detail is open or pending only trigger a new resolution.
- A click opens its row at once; a click on the open row (the transient
  popover closes on that mouse-down) closes it. Keyboard focus opens a row
  while the pointer is off the table; Escape closes until the pointer leaves
  that row. No pinning against hover.
- Rows leaving the table retire every reference to them (`rowsChanged`), fed
  from the rows actually on screen outside the conditionally shown table, so
  loading, empty and error states pass an empty set (builder finding on queue
  ticket 620, 2026-11-26).
- Trigger stays the whole row and the popover keeps its look and anchor.

## Why

Hover with a short open delay and a grace period is the native pattern for
detail on demand; click alone would remove what the maintainer likes. The
blink came from relying on per-window hover events for a popover that opens
under the pointer, so the decision uses the pointer's actual position while a
detail is open instead of more delay.

## What we tested

`AIUsageModelsHoverTests` (state machine): entering from outside, passing
over rows, switching rows, onto the detail, up and down off the detail onto
a row, leaving closes at once, click opens and does not pin, click on the
open row closes, Escape, keyboard focus, removed rows and an emptied table.

`AIUsageModelsHoverHostingTests` host the real `AIUsageCostsView` in an
`NSHostingView` inside a window kept off screen and move the pointer with
mouse-moved events sent through `NSApp`. Row positions come from the
rendered pixels (separator lines), independent of the controller, and the
row fill is checked in the pixels: every row (name, empty middle, price)
resolves to itself; from the open Meetings detail covering Drop Smart, up to
Drop Fast shows Drop Fast; from a detail down onto Agent, then back up past
every row; leaving the table closes; content scrolled under a resting
pointer follows the pointer. The real popover window cannot be shown in
tests, so its frame is a stand-in rectangle. Not verified in the running app
by this session (feature sessions do not launch the app).

## Rejected

- Hover only on the "N models" label: smaller target than the 2026-11-19
  whole-row request.
- Click only: loses hover, which the maintainer likes.
- Longer close delay: hides the blink less predictably and leaves the wrong
  detail on screen longer.
- Click to pin against hover: the maintainer wants the detail to follow the
  pointer (2026-11-27).
- Per-row NSView probes or per-row `onHover` flags as the source of truth:
  wrong geometry inside the ScrollView and missed events across windows.
- Moving the detail off the row: changes the look the maintainer likes.

2026-11-26 · PR #490; 2026-11-27 · branch `fix/costs-popover-row-under-pointer`
