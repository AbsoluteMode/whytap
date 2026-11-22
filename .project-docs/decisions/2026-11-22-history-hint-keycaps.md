---
id: history-hint-keycaps-2026-11-22
type: decision
title: History footer hints are separate keycap blocks
summary: The History footer was one grey line ("Click for copy   ⌘-click for several   Enter to paste to <app>") that read as one sentence; each hint is now its own block of keycaps and a short action, divided by hairlines, and only the app name shortens.
status: confirmed
tags: [history, island, toolbox, hotkeys, design]
canonical_for: [history-hint-keycaps]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer sent a screenshot of the footer "Click for copy   ⌘-click for several   Enter to paste to Clash Verge", said he likes the info block but its layout is confusing, and asked to separate the blocks visually.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/History/HistoryHoverView.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/History/HistoryMultiPasteTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-history-multi-paste.md, 2026-11-22-history-multi-copy.md]
---

# Context

The footer under History rows teaches the gestures. It was a single 9.5 pt
grey `Text` with three phrases split by three spaces. Without a visual break
the phrases ran together, and "Click for copy" next to "⌘-click for several"
did not say at a glance which key does what.

# Decision

`HistoryHoverView.hints(targetAppName:selectedCount:escapeClears:)` returns
the footer as a list of `HistoryHint` values (keys, action, optional target
app). `HistoryHintBar` draws each one as a block: compact keycaps through
`HotkeyHintView(style: .keycaps, size: .compact)`, then the action, with a
1 pt hairline between blocks. Every hint reads "key → what happens":

- no marks: [click] Copy | [⌘][click] Select | [↩] Paste to <app>
- marks: [click] Copy N | [↩] Paste N to <app> | [esc] Clear
- Toolbox with marks: [click] Copy N | [⌘][click] Unmark

The click is the SF Symbol `cursorarrow.click` in a keycap, Return the
`return` symbol, Escape the text "esc". Without a paste target the Paste
block is absent. The app name is its own `Text` with the lowest layout
priority and tail truncation, so a long name shortens and the hints stay
whole. Colors are `IslandInk` and the keycaps follow the color scheme, so the
Toolbox pane works in light and dark.

# Why

Keycaps are how Whytap shows keys everywhere else (`docs/hotkey.md`: one
entry point, caps side by side, modifiers as glyphs), so the key part is
recognisable without reading. Short verbs after the caps make every block the
same shape. "Select" instead of "for several": ⌘-click adds to a selection in
macOS, and the full "Select several" left the paste target only four letters
in a 312 pt island ("Clas…").

# What was tested

`HistoryMultiPasteTests` pin the blocks for every state (target, no target,
marks, Toolbox, empty app name), that only the app name is the target field,
that the keys are keycaps and that both SF Symbols exist on this macOS.
Offscreen renders at the island's 312 pt width, dark and light, for Telegram,
Clash Verge, a 29-character app name with and without marks, no target, marks
without target and Toolbox: "Paste to Clash Verge" fits whole; the long name
ends in "…" while every hint and "esc Clear" stay whole. Not verified in the
installed app.

# Rejected

- A text keycap "Click": `KeycapView` has no side padding for words, the
  letters touch the cap edges, and it is wider than the symbol.
- Changing word caps in `KeycapView` to add padding: also changes "Space" and
  other word caps on unrelated surfaces.
- Shrinking the font until "Select several" and the app fit: below 10 pt the
  footer is harder to read than the one it replaces.

2026-11-22, branch feature/history-hint-keycaps.
