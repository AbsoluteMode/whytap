---
id: monitor-server-status-optional-2026-11-23
type: decision
title: Server status is listed in Monitor only after servers are set up
summary: Monitor starts with no dashboards; the Server status board appears only while Monitor/servers.json names at least one server (or cannot be read) and was not deleted, and an empty picker says how to add a dashboard.
status: confirmed
tags: [monitor, hover, dashboards]
canonical_for: [monitor-server-status-listing]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-23 the maintainer saw Server status in Monitor, asked whether it was a test dashboard and said it must not be a required dashboard and should never have appeared there.
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Monitor/MonitorStore.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Monitor/MonitorHoverPanel.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Monitor/MonitorDashboardDeletionTests.swift
    confirmed_at: 2026-11-23
related: [2026-11-21-monitor-dashboard-delete.md]
---

# Server status is not a default dashboard

## Context

Both Monitor surfaces (the island panel and the legacy window) drew a
"Server status" row unconditionally; only the × (the `server-status` ID in
`removed-dashboards.json`) hid it. A user who never set servers up therefore
saw a board that opened onto "No servers connected". Whytap never created
`servers.json` itself, so there was no example file behind it: the row was
simply hardcoded. The maintainer took it for a test dashboard.

## Decision

- `MonitorStore.serverStatusListed` decides the row and the screen on both
  surfaces. It is true only while `Monitor/servers.json` exists and either
  names at least one server or cannot be read, and `server-status` is not in
  the deleted list.
- No file, or a valid file with an empty `servers` list: no row, no screen,
  no notice, no connection.
- A `servers.json` that is there but invalid keeps the row with the existing
  "could not be loaded" notice: that is a setup attempt, and hiding it would
  hide the mistake.
- Deleting with the × and `restore-dashboard server-status` work as before.
  While the deleted list is unreadable, a set-up Server status stays listed
  and paused; without servers it is still not listed.
- A picker with nothing to list says "No dashboards yet" and to ask a coding
  agent to add a custom dashboard or the servers' readings. It names no local
  path (setup belongs in the guide). The legacy window shows the same text.
- The agent's customization instructions say Server status is optional, not
  listed until set up, and that `servers.json` is not to be created unless the
  user asks to watch servers.
- No migration: Whytap never wrote `servers.json`, so every existing file was
  put there by the user or their agent.

## Why

A dashboard the user did not ask for looks like leftover test data. Servers
over SSH are a setup only some users have; the presence of their own
configuration is the explicit sign that they want the board.

## What we tested

- Unit tests from the user's side: a fresh Monitor folder lists no Server
  status, connects to nothing and Whytap writes no `servers.json`; an empty
  `servers` list lists nothing while custom boards stay; the board appears on
  the next reload once servers are added and leaves when the file is removed
  (no SSH afterwards); a broken file keeps the row with its notice; a deleted
  board stays unlisted after relaunch with servers set up; an unreadable
  deleted list pauses a set-up board and invents none without servers; both
  surfaces use `serverStatusListed`; the agent instructions.
- Not tested: the live island picker and the empty text over it.

## Rejected

- Listing whenever `servers.json` exists, also with an empty list: an empty
  file is not servers set up.
- Hiding a broken `servers.json`: the user would not learn why the board is
  missing.
- Adding `server-status` to every user's deleted list as a migration: writes
  user data and would hide the board from users who did set servers up.
- Removing Server status entirely: users with servers keep a working board.

2026-11-23 · PR: see the pull request that adds this file.
