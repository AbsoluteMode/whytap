---
id: drop-mode-switch-motion-2026-11-28
type: decision
title: The Smart/Fast switch has its own scoped animation, and settings capture reads keys off the main thread
summary: The Drop Mode tile symbol and the island's ON Smart/Fast status animate explicitly (symbol replace, status transition, 0.3 s smooth, none with Reduce Motion), scoped to those two views. The settings-history capture that follows every preference write reads provider keys in a detached task instead of on the main thread.
status: confirmed
tags: [island, hover, drop-mode, animation, backup, keychain, performance]
canonical_for: [drop-mode-switch-motion]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-27, with PR #519 installed (build 1787), the owner reported that switching between Smart and Fast still lags; the orchestrator asked for a measured cause and fix (task 96, second round).
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Backup/BackupViewModel.swift
    confirmed_at: 2026-11-28
related: []
---

# The Smart/Fast switch has its own scoped animation

## Context

After the hidden Settings model stopped rereading keys
(2026-11-27-settings-models-recompute-while-hidden.md), the owner still saw a
laggy Smart/Fast switch. Measurements on origin/main with the real island
mounted offscreen (never shown), clicked through the window-level hit bridge
and captured frame by frame, plus the real settings capture:

- Click path on the main thread: mouse-up handler 0.5 ms; first layout after
  the switch 7.1-7.6 ms median (a plain tile: 3.5-3.7 ms). Small; not a
  visible delay on its own.
- The visible switch was not an animation of its own. The ON Smart/Fast status
  in the island's right band appeared with zero intermediate frames in every
  round (a hard cut, while the hint orbs vanished the same way). The symbol
  only crossfaded when the tile's press-release spring carried it: a hotkey
  switch cut it, and in one 8-tool layout the third click cut it in both quiet
  runs.
- 600 ms after every preference write, `BackupViewModel` captures settings
  history on the main actor, reading every provider key (about 10 accounts)
  from the Keychain: 15.6-17.6 ms main-thread blocks (12-26 ms in noisier runs)
  after each switch, which lands in the next switch when toggling back and
  forth.

## Decision

- `IslandView.switchDropMode` sets the mode and status for clicks and the
  hotkey alike. The motion is scoped: the tile symbol uses
  `.contentTransition(.symbolEffect(.replace))` with
  `.animation(_, value: systemImage)`, and the right band animates on
  `dropModeStatus` with its existing opacity and scale transition. Both use
  `IslandDropModeControl.switchAnimation`: 0.3 s smooth, `nil` with Reduce
  Motion.
- `BackupViewModel.readCredentials` reads the capture's provider keys in a
  detached task. Capture timing, contents and the "unreadable key fails the
  capture" rule are unchanged.

## Why

The perceived lag is a switch that partly cuts and partly animates, and a
main-thread stall that hits repeated switching. A transaction around the
whole island (`withAnimation` over `dropMode`) was measured too: it animates
correctly but raised the first layout to 10.1 ms median (13.2 ms max); the
scoped version stays at 8.0-8.3 ms. Settings history must still save changes
immediately (2026-10-21-backup-capture-pacing.md), so the capture was moved
off the main thread rather than delayed.

## What was tested

- After the change, frame captures show the symbol changing through 7-17
  intermediate frames and the status through 7-9 (about 0.4 s) in every round;
  the capture left no main-thread gap over 6 ms (before: 15.6-17.6 ms) and
  still saved one settings version per switch.
- `IslandDropModeSwitchMotionTests` (click rounds and the hotkey) and
  `BackupCaptureMainThreadTests` fail on origin/main (status 0 intermediate
  frames in 3 of 3 rounds, hotkey symbol cut, 30 Keychain reads on the main
  thread) and pass with the change.

## Rejected

- One `withAnimation` over the whole island: more layout work on the first
  frame for no visible gain.
- A longer capture debounce: settings history saves changes immediately.
- Leaving the symbol to the press spring: the hotkey and some clicks cut it.

2026-11-28, PR: see fix/drop-mode-toggle-lag.
