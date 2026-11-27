---
id: costs-models-popover-hover-2026-11-26
type: decision
title: One open "Models used" detail for the Costs table, checked against the real pointer
summary: Each Costs row owned its popover state, and the detail opened under the resting pointer, so it blinked and could show another row's models. One state machine for the table now decides which row is open; while a detail is open the pointer's actual window and row are read, and the trigger, look and anchor stay.
status: confirmed
tags: [settings, costs, popover, hover, keyboard]
canonical_for: [costs-models-popover-hover]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the maintainer reported (ORCH-TASK 40, with a screenshot) that the pointer on the Agent row showed "Translation · Models used" beside Translation, and that the detail blinks and opens unpredictably; he likes its look.
    confirmed_at: 2026-11-26
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

## Decision

- `AIUsageModelsHoverState` is one pure state machine for the table: open row,
  pinned, row under the pointer, pointer on the detail, focused row, one
  pending open/close. Every row's popover binding reads `open == row.id`, so a
  popover can only show its own row.
- From rest the detail opens after 0.2 s of hover (sweeping opens nothing).
  While a detail is open, entering another row switches at once, like warm
  tooltips. Leaving both row and detail closes after a 0.3 s grace; returning
  or reaching the detail cancels it. Row fill is the row under the pointer,
  or the open row while the pointer is on its detail.
- While a detail is open, `AIUsageModelsHoverController` reads the topmost
  window under the pointer (`NSWindow.windowNumber(at:)`) and which row's
  visible frame contains it, every 100 ms and before any close, and turns
  differences into the same events. It stops when nothing is open.
- Click (or Return/Space on the focused name) pins and toggles. A transient
  popover closes on the mouse-down of the click meant to close it; a click on
  the same row within 0.4 s after that dismissal stays closed. Keyboard focus
  opens, Escape closes, a period change that removes the open row closes it.
- Rows leaving the table retire every reference to them: open, pinned,
  pending open, pointer row, focused row and the click-after-dismissal memory
  (`rowsChanged`). The view feeds the rows actually on screen from outside the
  conditionally shown table, so loading, empty and error states pass an empty
  set. A period change therefore closes a pinned detail and cancels a dwell in
  progress; nothing reopens until the pointer moves again (builder finding on
  queue ticket 620, 2026-11-26).
- Trigger stays the whole row and the popover keeps its look and anchor.

## Why

Hover with a short open delay and a grace period is the native pattern for
detail on demand; click alone would remove what the maintainer likes. The
blink came from relying on per-window hover events for a popover that opens
under the pointer, so the decision uses the pointer's actual position while a
detail is open instead of more delay.

## What we tested

`AIUsageModelsHoverTests`: rest → open after the delay; sweeping; A → B in
both event orders never keeps A; onto the detail stays; detail over another
row stays; detail → row switches; leaving both closes after the grace;
returning within the grace; pin and click-to-close after system dismissal;
focus and Escape; disabled; the controller case of a detail appearing under
the resting pointer; a removed row during the dwell delay, an emptied table
(loading/empty/error) during the dwell and with a pinned detail, rows that
stay keeping their state. Not verified in the running app by this
session (feature sessions do not launch the app).

## Rejected

- Hover only on the "N models" label: smaller target than the 2026-11-19
  whole-row request.
- Click only: loses hover, which the maintainer likes.
- Longer close delay: hides the blink less predictably and leaves the wrong
  detail on screen longer.
- Moving the detail off the row: changes the look the maintainer likes.

2026-11-26 · PR: see branch `fix/costs-models-popover-hover`
