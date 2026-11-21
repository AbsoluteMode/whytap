---
id: history-backdrop-always-2026-11-21
type: decision
title: History always has a readable backdrop
summary: The hover History drawer and its preview use the shared drawer backdrop on every macOS version, the macOS 14/15 backdrop is darkened to 80%; Reduce transparency gives every hover drawer card an opaque dark backdrop; rows show their text on one line without leading line breaks.
status: confirmed
tags: [history, island, hover, glass, accessibility]
canonical_for: [history-drawer-backdrop, hover-backdrop-reduce-transparency, history-row-text]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user saw History on another Mac drawn without a backdrop (dark rows, the window underneath showing around and between them) while his own Mac showed one, and asked to find out why.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandHoverGlass.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandView.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandDropModeControl.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/History/HistoryHoverPreview.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/History/HistoryBackdropTests.swift
    confirmed_at: 2026-11-21
related: [2026-10-17-native-hover-glass.md, 2026-11-22-history-multi-paste.md]
---

# History always has a readable backdrop

## Context

The hover drawer draws one backdrop behind every panel: native Regular glass
on macOS 26 and later, `IslandDetachedHoverPanelBackground` (ultra-thin
material with a dark wash) on macOS 14/15. History was the exception: the
drawer passed `showGlass: hoverPanelMode != .history || usesNativeLiquidGlass`,
so on macOS 14/15 its background was `Color.clear`. Its rows and the mode
segment kept their own 82% dark plates, but the gaps between them, the edges
and the area around the "Click for copy" hint showed the window underneath.
The [native hover glass decision](2026-10-17-native-hover-glass.md) kept that
older "floating rows" fallback unchanged when it moved macOS 26 to the shared
backdrop.

The maintainer runs a newer macOS and sees glass; the reported Mac matched the
macOS 14/15 path exactly. Nothing else in the code removes the backdrop:
appearance is forced dark for the island window, no Whytap setting, permission,
display or first-launch state switches it off.

## Decision

- No hover drawer card can turn its backdrop off. `showGlass` is removed and
  History uses `.islandHoverGlassSurface()` like every other panel. On macOS
  14/15 that is the legacy material, on 26+ native glass.
- The History preview bubble uses the same surface on every system instead of
  a 46% black wash on macOS 14/15.
- `IslandHoverBackdropPolicy` chooses the backdrop: Reduce transparency →
  `opaque` (solid dark `#1C1C1F` with a thin rim) on every system; otherwise
  native glass when available, else the legacy material. The rule applies to
  every user of `islandHoverGlassSurface` (drawer, music strip, History
  preview).
- The macOS 14/15 backdrop (`IslandDetachedHoverPanelBackground`) puts an
  80% black layer (`legacyDarkLayerOpacity`, was 25%) over its material, so
  small text under any hover panel does not read through even where the
  material does not blur. The specular top, edge lens and rim keep the glass
  look. This applies to every macOS 14/15 hover panel, not only History.
- History's own row, segment and hint plates are unchanged; they sit on the
  backdrop now.
- A History row shows its entry on one line without leading line breaks or
  indentation (see Row text).

## Why

A panel that is unreadable over a busy window is a defect regardless of the
macOS version. Reusing the drawer's existing backdrop keeps one visual system
and adds no new material. The explicit opaque card makes Reduce transparency
independent of how each macOS version renders materials and glass with that
setting.

## What we checked

- Offscreen renders of the History drawer over a bright chat-like window:
  the former see-through drawer, the legacy backdrop and the Reduce
  transparency card (`HistoryBackdropTests.testRenderHistoryBackdrops`,
  `WHYTAP_HISTORY_BG_RENDER_DIR`). They force the macOS 14/15 row style
  (`IslandHoverGlass.drawsLegacyPathForReview`), so "before" matches the
  reported screen: dark rows, see-through gaps.
- A probe image in the same run captures SwiftUI's `.ultraThinMaterial` and
  `NSVisualEffectView` (behind and within window) over text: offscreen
  capture draws no blur for any of them (crisp text or a flat fill). The
  first legacy render, with the former 25% wash, therefore showed the
  no-blur worst case, and the text under the panel read through. The 80%
  layer keeps that worst case readable; live blur only improves it.
  macOS 14/15 itself was not available.
- The "Click for copy" hint is a separate plate by design (hint row under the
  results, the same plate style as rows); on the backdrop it reads as the
  drawer's footer.
- Text cut at the left ("nternet Accounts,"): see the section below.

## Row text

The row lays out its text from the first character with tail truncation;
nothing in the row, the feed or the clipboard store removes leading
characters. An offscreen render of `nternet Accounts,` shows exactly that
string, so a row reading "nternet Accounts," holds a copy that began there
(a selection that missed the first letter). That part is not a layout bug.

The same renders found a real one: a copy that starts with a line break
showed an empty row, and leading indentation shifted the text. Rows now show
`HistoryHoverContent.rowText`: lines trimmed, blank lines dropped, the rest
joined with spaces. Copy, paste and the preview still use the full entry.

## Rejected

- Keeping floating rows and only raising their opacity: the gaps and
  surroundings would still show the window underneath.
- A fully opaque card for every macOS 14/15 user: loses the glass look; an
  80% layer under the specular and rim keeps it and is readable without blur.
- Keeping the 25% wash and relying on live blur: the blur could not be shown
  offscreen, and without it the window underneath read through.
- Detecting Reduce transparency only through the system's material rendering:
  not testable and differs between macOS versions.

2026-11-21 · PR: see the branch `claude/history-background-2afdcd`.
