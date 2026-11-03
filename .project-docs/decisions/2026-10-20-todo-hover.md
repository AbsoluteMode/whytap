---
id: whytap-todo-hover-2026-10-20
type: decision
title: Compact To-do list and completion history inside hover
summary: The To-do catalog entry opens an inline task list with Return capture, reversible completion and timestamped history.
status: confirmed
tags: [todo, tasks, hover, history, planner]
canonical_for: [todo-hover]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: 2026-10-20 chat; requested a compact hover list with an input and Enter, full text on hover, click to complete/reopen, completed rows below active tasks until the next opening, and History with completion date/time.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Planner/TodoHoverView.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Planner/PlannerStore.swift
    confirmed_at: 2026-10-20
related: [2026-10-19-planner.md, 2026-10-21-calendar-hover.md, 2026-11-03-todo-helper.md, 2026-11-03-todo-tree.md]
---

## Decision

To-do opens inside the existing hover drawer, preserving catalog identity and
saved slot/hotkey mappings. Calendar's subsequent move into Hover is specified
in [Calendar in Hover](2026-10-21-calendar-hover.md). Tasks use
the existing private atomic archive and backup path.

The active view contains incomplete tasks and tasks completed during this opening.
Completion moves a row below active tasks. The next opening excludes completed
rows; History lists all completed tasks, latest known completion first. Clicking
a completed task reopens it. A new completion stores its actual date/time; old
archives decode an absent timestamp as unknown. Editing an already completed task
does not invent or change its completion time.

The input retains its draft across dismissals and save failures. Visibility or a
retained draft prevents restore/update restart; it does not prevent normal backups.
Native help tooltips show full truncated task titles. Native button semantics
preserve full accessibility labels and click/keyboard actions.

## Why

The user selected fast task capture in hover after trying the larger Planner
surface. Keeping completed rows until dismissal makes immediate undo available
without leaving the active list. Separating History keeps the next opening short.
Optional timestamps preserve older saved tasks and encrypted archives.

## Verification and limits

Temporary-store tests cover completion/reopen, opening boundaries, history order,
legacy decoding, failed writes and retained drafts. Offscreen native renders cover
compact and larger island widths. Physical keyboard/VoiceOver, tooltip timing and
compositor appearance remain installed-app acceptance.
