---
id: eye-hides-hover-not-explicit-panels-2026-11-28
type: decision
title: The island's eye hides the drawer on mouse hover, not panels the user explicitly opens
summary: With "Hide Hover and Music" on, an explicit request (Settings -> Features Open/Edit, a tool's hotkey such as Option N, a whytap link) opens the tool's panel; the eye hides only the drawer appearing under the mouse and the hover music strip. The explicitly opened drawer behaves as usual until it closes, and the eye state never changes.
status: confirmed
tags: [island, hover, eye, settings, hotkeys]
canonical_for: [eye-explicit-panels]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 (orchestrator card 42, spec REV 16) the owner chose "Open the panel" after the release-batch inquisition found that Settings -> Features Open/Edit, Option N and similar requests did nothing while the eye was on.
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/DynamicIsland/IslandEyeExplicitPanelTests.swift
    confirmed_at: 2026-11-28
related: []
---

# The eye hides hover, not explicit panels

## Context

`IslandView.isHoverExpanded` required the eye ("Hide Hover and Music") to be
open, so every programmatic panel request was dropped while it was closed:
Edit for Vocab and Filler (their only place in Settings), Open for Case,
To-do, History, Display, Notify and Monitor, and inline tools' hotkeys,
although Settings says their shortcuts work either way. Nothing appeared and
no message explained why.

## Decision

- The eye hides only the drawer appearing under the mouse, and the hover
  music strip; the compact music wing stays
  (`docs/decisions/2026-06-24-eye-keeps-compact-music-wing.md`).
- A non-glance `programmaticHoverPanelRequest` (Settings -> Features, a tool's
  hotkey, a whytap link) with the eye on sets `explicitlyOpened`. While it is
  set, the pointer and keyboard hold the drawer as usual; it is cleared when
  the drawer closes (Escape, an outside click, the usual programmatic
  collapse) or the eye is closed again. The eye's state never changes.
- `IslandView.hoverDrawerShown` is the one gate: meeting suggestions, agent
  flow and Case approval still win.
- Brightness keys are unchanged: with the eye on they are not intercepted at
  all (`BrightnessKeys`), so their glance request never reaches the island;
  a glance also does not count as explicit. The Brightness tool opened from
  Settings or its own hotkey is explicit and opens.

## Why

The user asked for the panel; hiding hover is about the mouse passing over
the notch. Opening the eye first would be a hidden prerequisite.

## What we tested

- The gate: plain mouse hover and a glance stay hidden with the eye on; an
  explicit request opens; the pointer keeps it; policy still wins.
- In an offscreen island with the eye on: History, Vocab, Filler, To-do,
  Display, Notify and Monitor requests open their panel, take clicks and close
  through the island's dismissal; the eye stays on; a brightness glance does
  not open; closing the eye closes an explicitly opened panel.

## Rejected

- A hint "Hover is hidden - open the eye": an extra step for an explicit
  request.
- Turning the eye off on an explicit request: changes a setting the user did
  not touch.

2026-11-28 · orchestrator card 42, spec REV 16
