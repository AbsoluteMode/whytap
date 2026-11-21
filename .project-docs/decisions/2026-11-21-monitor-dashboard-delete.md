---
id: monitor-dashboard-delete-2026-11-21
type: decision
title: Monitor dashboards can be deleted and stay deleted while their collector runs
summary: The × on a custom Monitor dashboard row (Cancel-first confirmation) records its ID in Monitor/removed-dashboards.json and removes its snapshot files; collectors and their scripts are never touched, and installing the dashboard again lists it again.
status: confirmed
tags: [monitor, hover, dashboards]
canonical_for: [monitor-dashboard-delete]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user asked to add a way to delete Monitor dashboards.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Monitor/MonitorDashboardRemoval.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Monitor/MonitorStore.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Monitor/MonitorDashboardDeletionTests.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: scripts/tests/test_monitor_dashboard_install.py
    confirmed_at: 2026-11-21
  - type: user-confirmed
    reference: On 2026-11-21 the user chose to delete the snapshot file and remember its ID (option A, "delete and remember").
    confirmed_at: 2026-11-21
  - type: user-confirmed
    reference: On 2026-11-21 the user asked for an × on each row instead of right-click, no chevron and the scroller moved to the right.
    confirmed_at: 2026-11-21
related: []
---

# Deleting Monitor dashboards

## Context

Monitor lists every valid snapshot in `Monitor/dashboards/`. There was no way
to remove a board from Whytap. The snapshots are written by the user's own
collectors (in practice launchd agents that rewrite their file every few
minutes), which Whytap neither installs nor owns.

## Decision

- A custom dashboard's row in the picker has an **×** on its right. Server
  status is built in and has none. There is no context menu: the island has
  no right-click interactions anywhere (the user's correction on 2026-11-21,
  after a first version put Delete… in the row and heading context menus).
  Rows have no chevron, since a click on a row plainly opens it, and the
  scroller sits in the panel's right margin instead of over the cards.
  The row card itself shows hover, press and keyboard focus. The × has its
  own hover, press and focus states, all shown only while it is enabled: a
  delete in progress disables it, and a disabled × under the pointer looks
  like any disabled ×.
- Delete asks first: Cancel is the first button and takes Escape, Delete has
  no key equivalent (the meeting and clipboard pattern).
- Confirming records the dashboard ID in `Monitor/removed-dashboards.json`
  (`{"removed": [...]}`, atomic, mode 0600) and then removes every snapshot
  file in `dashboards/` that decodes to that ID. Other dashboards, collectors,
  their scripts, launchd agents and `servers.json` are never touched.
- `MonitorStore.reloadFiles` skips listed IDs, so a collector that rewrites
  the snapshot does not bring the board back, also after relaunch. A hidden
  board is not counted as a broken file.
- Deleting the board that is open returns to the picker. Another Monitor
  surface (island and Toolbox each have a store) drops it on its next reload
  and shows its existing "no longer available" text if it had it open.
- `customize.py install-dashboard` removes the ID from the list, so installing
  a board again lists it again. Snapshot and list change as one step: both new
  files are prepared first, the snapshot is committed, then the list; if the
  list cannot be committed the previous snapshot is put back (a first install
  removes its file). An unreadable list, an unwritable folder or any failed
  write leaves both files as they were, so a deleted board's collector
  snapshot never reappears and a retry works.
- Whytap's Delete (hide the ID, remove the files) and the installer's change
  both run entirely under an exclusive `flock` on
  `Monitor/removed-dashboards.lock`, re-reading the list inside the lock, so
  neither loses or undoes the other's change. Whytap waits at most 2 s, the
  installer 5 s; a busy lock fails without changes.
- An unreadable list shows every board with a notice and makes Delete fail
  with an alert instead of overwriting the list.

## Why

- Deleting only the file is undone by the collector within minutes.
- Stopping or deleting the collector would reach into the user's own programs
  and launchd configuration, which Whytap does not own.
- A small ID list in the Monitor folder is covered by the existing portable
  backup of owned Monitor files and is easy for an agent to read and fix.

## What we tested

- Unit tests from the user's side: deleting one of three boards keeps the other
  two, the collector script and `servers.json`; Cancel changes nothing; the
  deleted board stays gone in a new store (relaunch) and after the collector
  rewrites it; deleting the open board returns to the picker while Cancel and
  failures keep it open; a second surface gets `alreadyGone`; duplicate copies
  are all removed; an unreadable list fails without deleting; Server status and
  invalid IDs are refused; the list file is 0600 and round-trips; the alert
  orders Cancel first with Delete keyless.
- `scripts/tests/test_monitor_dashboard_install.py` (10 tests): an unreadable
  list keeps the previous snapshot on `--replace` and creates nothing on a
  first install (a retry after fixing it installs); an unwritable snapshots
  folder changes neither file; a failed list save puts the previous snapshot
  back, or removes a first install's file; a failed snapshot write keeps the
  list; re-listing keeps other deletions with mode 0600; `--dry-run` changes
  nothing; the installer waits for a held lock and keeps the deletion saved
  meanwhile; a lock that stays busy fails without changes. No temporary files
  are left behind. Swift: Delete fails cleanly while the installer holds the
  lock and succeeds after; earlier saved deletions are kept.
- The builder's reviews (queue tickets 298 and 299) found the snapshot written
  before a list failure, a lost update between list writers and the list
  committed before a failed snapshot write; all three led to the transaction
  and lock above, and the builder's reproducers pass.
- The builder's offscreen probe (queue ticket 304) found the disabled × still
  drawing its hover surface under the pointer. The states now come from one
  pure table (`MonitorPickerControlAppearance`), tested for every
  combination, and a pixel test renders the × idle, hovered, disabled and
  disabled under the pointer (the last two must match).
- Not tested: the real × and alert over the live island panel.

## Rejected

- Deleting only the snapshot file: the collector writes it again.
- Hiding without deleting the file: leaves stale data behind for no reason.
- Compare-before-rename without a lock: still loses an update in the window
  between the check and the rename.
- Stopping or deleting the collector: not Whytap's to touch.
- Delete… in a context menu: the island has no right-click interactions.

2026-11-21 · PR: see the pull request that adds this file.
