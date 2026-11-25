---
id: feature-icons-2026-11-25
type: decision
title: Every feature in Settings → Features has the icon its island tool or shortcut already shows
summary: The Features list and each feature screen's header show one monochrome SF Symbol per feature, the same weight and size, without a coloured plate. A feature with an island tool takes that tool's icon from HoverToolRegistry; the others take the icon their shortcuts carry in Hotkeys.
status: confirmed
tags: [settings, features, icons]
canonical_for: [feature-icon]
verified_at: 2026-11-25
sources:
  - type: user-confirmed
    reference: On 2026-11-25 the maintainer, looking at the Features list, asked what we thought of adding icons, and agreed to icons taken from the island and Toolbox, monochrome and in the header too (ORCH-99, via the orchestrator).
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Settings/Features/FeatureCatalog.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Tests/SidekeyTests/Settings/FeatureIconTests.swift
    confirmed_at: 2026-11-25
related: []
---

## Context

The Features list ("What Whytap can do") was text only. Most features
already have an icon elsewhere in Whytap: their island tool, or their row in
Hotkeys.

## Decision

- `AppFeature.symbol` is the feature's icon. Translate & Subtitles,
  Screenshots, To-do, Case, Notify and Monitor take their island tool's icon
  (`AppFeature.islandTool`, read from `HoverToolRegistry`, so a changed tool
  icon changes here too): character.bubble, viewfinder (Shot), checklist,
  key.horizontal, bell.badge, waveform.path.ecg.
- Drop, the Agent, Meeting Notes and Google search take the icon their
  shortcuts carry in Hotkeys: mic, sparkles, record.circle,
  magnifyingglass. Hover, the tools' grid: square.grid.2x2.
- `FeatureIcon` draws it in one style: regular weight, secondary text
  colour, no plate; 15 pt in a list row, 19 pt beside the name in the
  feature screen's header (`FeatureScreenHeader`, used by every screen).
  Quiet rows (Off, Not set up) dim the icon with the text.

## Why

- The same picture in the list, the screen and the island shows they are one
  thing; Maxim asked for icons from the island and Toolbox.
- One colour and weight keeps the list calm and lets the status words carry
  the state; coloured plates would compete with them.

## What we tested

`FeatureIconTests`: features with an island tool show that tool's icon
(Screenshots = Shot's viewfinder); the others show their Hotkeys icon; every
icon is a real symbol on macOS 14 and no two features share one; offscreen
pictures of the list and of a feature header in both appearances.

## Rejected

- Coloured rounded plates like System Settings: Maxim asked for monochrome.
- New icons for features that already have one: the link to the island
  would be lost.

2026-11-25 · PR (this branch)
