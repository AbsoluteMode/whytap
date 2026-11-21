---
id: clipboard-no-entry-delete-2026-11-21
type: decision
title: Clipboard history has no per-entry Delete
summary: The Delete… context-menu item on clipboard rows in hover History and Toolbox History is removed, with its confirmation, deletion flow and store method; only the 50-entry cap removes clipboard rows.
status: confirmed
tags: [clipboard, history, island]
canonical_for: [clipboard-entry-deletion]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user asked to remove the delete function from clipboard history, after learning it was reached by right-click and confirmed by a system alert, and having stated that the island has no right-click interactions.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/History/HistoryHoverView.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/History/SQLiteHistoryStore.swift
    confirmed_at: 2026-11-21
related: [2026-10-22-clipboard-entry-delete.md]
---

# No per-entry Delete in clipboard history

## Context

Clipboard rows in hover History and Toolbox History had Delete… in a
right-click context menu, confirmed by a system alert
([earlier decision](2026-10-22-clipboard-entry-delete.md)). The same day the
user stated that the island has no right-click interactions, and a system
alert in Monitor had opened under the island where it could not be clicked.

## Decision

- Clipboard rows have no Delete and no context menu, in the island and in
  Toolbox → History. A click still copies and Return still pastes.
- `ClipboardEntryDeletion`, its alerts, the `deleteHistoryCard` plumbing and
  `SQLiteHistoryStore.deleteClipboardEntry` are removed.
- A clipboard row leaves the history only through the 50-entry cap, which
  removes its image sidecar too.
- Kept: `secure_delete` on the History connection, the one-time free-page
  scrub and the modal guard on History key monitors (harmless for any alert).

## Why

The user asked for it. The feature depended on right-click, which the island
does not use, and on a system alert, which can open under the island.

## What we tested

`swift build`, the full `swift test`, and the History, Toolbox and island
suites. The free-page scrub test no longer deletes a row before scrubbing; it
still checks that every row, sidecar and id survives the scrub and that a new
id follows the newest one.

## Rejected

- Replacing the context menu with an × on each row: not requested; the user
  chose to remove the function.

## Consequences

A copy recorded by mistake (for example a secret from an app that does not
mark its copies) stays in local History until 50 newer copies push it out.
Copies marked concealed, transient or auto-generated are still never
recorded.

2026-11-21 · PR: see the pull request that adds this file.
