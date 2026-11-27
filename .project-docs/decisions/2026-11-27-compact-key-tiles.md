---
id: compact-key-tiles
type: decision
title: Compact provider key tiles that fit the Settings window
summary: API keys tiles become compact icon-left cards so the whole tab fits the default Settings window without scrolling.
status: confirmed
tags: [settings, keys, layout]
canonical_for: [provider-key-tile-size]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: On 2026-11-27 the maintainer asked to make Keys & models → API keys smaller so it fits one screen without scrolling (task 84).
    confirmed_at: 2026-11-27
  - type: user-confirmed
    reference: On 2026-11-27 the maintainer asked to show Key works in green instead of a checkmark badge and approved the renders.
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/ProviderKeyTiles.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Tests/SidekeyTests/Settings/APIKeysFitTests.swift
    confirmed_at: 2026-11-27
related: [2026-10-21-provider-key-tiles.md, 2026-11-19-on-device-dictation.md]
---

# Compact provider key tiles

## Context

The 2026-10-21 square tiles took a tile's full column width as its height.
With eight tiles (seven providers and Tavily) under the On this Mac card the
tab overflowed: 7–12pt at the default 1040×660 window, about 400pt at the
960×560 minimum, where three columns made each square ~210pt tall. The owner
had to scroll to reach OpenRouter, OpenAI, Anthropic and the rest.

## Decision

Each tile is a compact card: 22pt provider icon on the left, then name, use
(Speech recognition / Language models / …) and the key status. `ProviderGrid`
keeps its column rule (4 from 700pt, 3 from 450pt) and the inline form under
the selected row, but each row is as tall as its tallest tile instead of
square. The On this Mac card is unchanged. A key whose last check passed
shows "Key works" in the theme's success green (`MacSettingsTheme.green`,
#196F3D on light, #64D98B on dark); every other status keeps its colour.

## Why

- Same information at about a third of the height. The owner asked for a
  green "Key works" so a working key stands out from a rejected one; the
  theme green keeps readable contrast on both themes, unlike raw systemGreen
  on white.
- Variable row height lets a long status ("Key not accepted. Regional keys
  aren't supported yet.") wrap instead of being truncated, while ordinary
  rows stay ~70pt.
- Icon-left matches the On this Mac card directly above and the Models rows.

## What we tested

`APIKeysFitTests` hosts the real Keys & models view offscreen at the Settings
pane sizes (window minus 220pt sidebar, 1pt separator, 40pt title bar) and
asserts the scroll view's document fits: the owner's keys at default and at
minimum size, and every key with the longest statuses at default size. The
old squares fail all three; the compact tiles pass. Review renders are written
with `WHYTAP_API_KEYS_RENDER_DIR`.

## Rejected

- Shrinking the squares only: still square, still overflows at three columns.
- Plain list rows: loses the provider grid the owner chose on 2026-10-21 and
  pushes the inline form further from its tile.
- Truncating status to one line: hides the reason a key was rejected.
- A green check badge on the logo: proposed, then dropped by the owner in
  favour of the green status text.

2026-11-27 · branch `feature/compact-api-keys`; the owner approved the renders (green Key works, no badge).
