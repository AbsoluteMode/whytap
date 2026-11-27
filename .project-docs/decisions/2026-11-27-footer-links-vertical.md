---
id: footer-links-vertical-2026-11-27
type: decision
title: Settings footer links are stacked one per row
summary: The Whytap, Help and GitHub links in the Settings sidebar footer sit in a vertical list, each with its icon and full label, left-aligned with the version line, instead of one horizontal row that truncated the labels.
status: confirmed
tags: [settings, footer, links, layout]
canonical_for: [settings-footer-link-layout]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: On 2026-11-27, after build 1780, the owner reported that the three footer links truncated ("Whyt…", "GitH…") and asked to arrange them vertically, relayed by the orchestrator as task 71 REV 1.
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsProjectFooter.swift
    confirmed_at: 2026-11-27
related: []
---

# Settings footer links are stacked one per row

## Context

Adding the Help link (task 71) made three links in one row of the narrow
Settings sidebar; "Whytap" and "GitHub" were cut to "Whyt…" and "GitH…".

## Decision

A vertical list, one link per row: icon and full label, 26 pt rows with no
extra gap, the same left edge as the version line above. Each row is one
button-like target spanning the sidebar width (hover highlight, pointing
hand, keyboard focus and the accessibility label and hint are unchanged).

## Why

The sidebar width is fixed by the window; a label that must never truncate
needs its own row. Full-width rows are also an easier target.

## What was tested

An offscreen layout test checks three rows, one left edge, no overlap and
room for a whole label; the existing pointing-hand and What's New footer
tests keep counting three links.

## Rejected

- Shorter labels or icon-only links: Help and GitHub would lose their names.
- Two rows (two plus one): uneven and still truncates at narrow widths.

2026-11-27, PR: see feature/footer-links-vertical.
