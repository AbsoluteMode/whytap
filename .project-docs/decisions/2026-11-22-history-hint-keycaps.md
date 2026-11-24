---
id: history-hint-keycaps-2026-11-22
type: decision
title: History footer hints are separate plain-text blocks
summary: The History footer was one grey line that read as one sentence; each hint is now its own plain-text block divided by hairlines. A keycap and icon version shipped in build 1724 and was removed at the maintainer's request.
status: confirmed
tags: [history, island, toolbox, design]
canonical_for: [history-hint-keycaps]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer sent a screenshot of the footer "Click for copy   ⌘-click for several   Enter to paste to Clash Verge", said he likes the info block but its layout is confusing, and asked to separate the blocks visually.
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: On 2026-11-23, after build 1724 showed keycaps and SF Symbol icons in the footer, the maintainer said nobody asked for icons in History and asked to remove them.
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/History/HistoryHoverView.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/History/HistoryMultiPasteTests.swift
    confirmed_at: 2026-11-23
related: [2026-11-22-history-multi-paste.md, 2026-11-22-history-multi-copy.md]
---

# Context

The footer under History rows teaches the gestures. It was a single grey
`Text` with three phrases split by three spaces and scaled down to fit
(`minimumScaleFactor(0.7)`). Without a visual break the phrases ran together.

# Decision

`HistoryHoverView.hints(targetAppName:selectedCount:escapeClears:)` returns
the footer as a list of `HistoryHint` values (text and optional target app).
`HistoryHintBar` draws each as a plain-text block, with a 1 pt vertical
hairline between blocks. No icons, no keycaps.

- no marks: Click to copy | ⌘-click for several | Enter to paste to <app>
- marks: Click to copy N | Enter to paste N to <app> | Esc to clear
- no target: no Enter block; Toolbox with marks ends with ⌘-click to unmark

The row is tried at 9.5, 9, 8.5 and 8 pt (`ViewThatFits`); the first size at
which everything fits wins, as the old line scaled to fit. Only when 8 pt is
still too wide does the app name, its own `Text` with the lowest layout
priority, shorten with "…"; the hints stay whole. Colors are `IslandInk`, so
the Toolbox pane works in light and dark.

# Why

Hairlines make three phrases three blocks without new vocabulary; the
wording is the one the maintainer already knew from the footer. Stepping the
font keeps the target app readable: at a fixed 9.5 pt "Telegram" became "T…"
in the island's 312 pt width.

# What was tested

`HistoryMultiPasteTests` pin the blocks for every state (target, no target,
marks, Toolbox, empty app name), that only the app name is the target field,
and that the footer source has no `HotkeyHintView`, `Image(` or
`cursorarrow.click`. Offscreen renders at 312 pt, dark and light, before
(keycaps, build 1724) and after: Telegram and Clash Verge fit whole, a
29-character name ends in "…" with every hint whole. Not verified in the
installed app.

# Rejected

- Keycaps through `HotkeyHintView` with SF Symbol icons for click and Return
  (shipped 2026-11-22 in build 1724): the maintainer did not ask for icons
  and asked to remove them.
- A fixed font with truncation only: the app name was cut to its first
  letter.

2026-11-22, branch feature/history-hint-keycaps; revised 2026-11-23, branch
feature/history-hint-plain.
