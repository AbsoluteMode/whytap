---
id: toolbox-system-background-2026-11-20
type: decision
title: Toolbox tool panes share the Settings background
summary: Island panels embedded in Settings -> Toolbox (Vocab, Filler, Case, the language pickers, Notify, History, Monitor) no longer sit on a dark preview card; they use the Settings background and follow its light or dark appearance, while the island itself stays dark.
status: confirmed
tags: [settings, toolbox, appearance, island]
canonical_for: [toolbox-system-background]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user showed the Vocab pane as a dark card inside light Settings and said the background of a tool's settings differs from tool to tool; it must be the system one.
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandInk.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Tests/SidekeyTests/Settings/ToolboxPaneBackgroundTests.swift
    confirmed_at: 2026-11-20
related: [2026-10-20-toolbox-mini-apps.md]
---

## Context

Settings follows the macOS light or dark appearance. Toolbox panes that embed
an island panel drew it on a fixed dark card with a forced dark color scheme,
a deliberate "preview of the island". Display, Drop Mode, Record and
Translate drew in the Settings theme. In light Settings the panes looked like
two different products.

## Decision

- The dark card and the forced dark scheme are removed
  (`settingsIslandPreview` adds nothing). Notify's own forced dark scheme is
  removed too.
- The embedded panels take their foreground from `IslandInk`, a dynamic
  color: white in a dark appearance, near-black in a light one. The island's
  window is always dark, so the island draws exactly as before.
- The opacities tuned for white on dark are kept for both appearances.
- Row and plate surfaces are dynamic too (`IslandInk.row`, `IslandInk.plate`).
- Light Notify uses the Settings secondary text color for message bodies,
  timestamps, descriptions and the inactive tab label. A history item without
  an action uses static text and retains its Copy menu. The dark island keeps
  its existing text and inactive row treatment.

## Why

A tool's pane in Settings is a settings surface, not a picture of the island.
One background makes the panes read as one family and removes the dark slab
from light Settings.

## What was checked

- Offscreen renders of Vocab, Filler and the input-language picker on the
  Settings background in light and dark: text, chips, the search field and
  the clear marks are readable in both.
- Tests: no dark card or forced dark scheme remains; the embedded panels have
  no hardcoded white; the ink resolves to white in dark and near-black in
  light.
- The builder's review measured 1.04:1 for a Notify title on light Settings:
  Notify rows and History rows kept fixed dark fills. They now use
  `IslandInk.row` and `IslandInk.plate`, which are the same dark surfaces in
  the island and light ones on light Settings. Notify (History and Sources)
  and History were rendered with synthetic rows in both appearances.
- Not rendered: Case and Monitor panes (they need live stores), and nothing
  was checked in the running app or in the island.

## Rejected

- Keep the dark card and darken the other panes: Settings follows the system.
- A separate Settings copy of each panel: two implementations to keep equal.

2026-11-20.
