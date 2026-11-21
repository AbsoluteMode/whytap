---
id: monitor-dashboard-delete-2026-11-21
type: decision
title: Monitor dashboards can be deleted and stay deleted while their collector runs
summary: Delete… on a custom Monitor dashboard (Cancel-first confirmation) records its ID in Monitor/removed-dashboards.json and removes its snapshot files; collectors and their scripts are never touched, and installing the dashboard again lists it again.
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
related: []
---

# Deleting Monitor dashboards

## Context

Monitor lists every valid snapshot in `Monitor/dashboards/`. There was no way
to remove a board from Whytap. The snapshots are written by the user's own
collectors (in practice launchd agents that rewrite their file every few
minutes), which Whytap neither installs nor owns.

## Decision

- A custom dashboard's row in the picker, and the heading of an open custom
  dashboard, have **Delete…** in their context menu. Server status is built in
  and has none.
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
  a board again lists it again. It changes the list before writing the
  snapshot: an unreadable list or a failed list save stops the install with
  nothing written, so a reinstall keeps the previous snapshot and a first
  install leaves no file behind that would block a retry.
- Whytap and the installer change the list only while holding an exclusive
  `flock` on `Monitor/removed-dashboards.lock`, re-reading the list inside the
  lock, so neither overwrites a deletion or re-listing the other just saved.
  Whytap waits at most 2 s, the installer 5 s; a busy lock fails without
  changes.
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
- `scripts/tests/test_monitor_dashboard_install.py`: an unreadable list keeps
  the previous snapshot on `--replace` and creates nothing on a first install
  (a retry after fixing the list installs); re-listing keeps other deletions
  with mode 0600; `--dry-run` changes nothing; the installer waits for a held
  lock and keeps the deletion saved meanwhile; a lock that stays busy fails
  without changes. Swift: Delete fails cleanly while the installer holds the
  lock and succeeds after; earlier saved deletions are kept.
- The builder's first review (queue ticket 298) found the snapshot written
  before a list failure and a lost update between list writers; both are the
  reason for the order and the lock above.
- Not tested: the real context menu and alert over the live island panel.

## Rejected

- Deleting only the snapshot file: the collector writes it again.
- Hiding without deleting the file: leaves stale data behind for no reason.
- Compare-before-rename without a lock: still loses an update in the window
  between the check and the rename.
- Stopping or deleting the collector: not Whytap's to touch.

2026-11-21 · PR: see the pull request that adds this file.
