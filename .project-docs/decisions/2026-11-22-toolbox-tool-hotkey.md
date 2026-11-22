---
id: toolbox-tool-hotkey-2026-11-22
type: decision
title: Settings -> Toolbox sets a tool's hotkey at the top of its pane, and a selected tile is a soft accent wash
summary: A selected Toolbox tool shows a pinned Hotkey block (Set, or the current keys with Change and Remove) that saves at once through the Hotkeys Save path and records with the recorder shared with Settings -> Hotkeys; the selected tile is an accent wash on its circle with a bold caption, and tiles take keyboard focus like native buttons, with a circular focus ring.
status: confirmed
tags: [settings, toolbox, hotkeys, accessibility, design]
canonical_for: [toolbox-tool-hotkey, toolbox-tile-selection]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22, testing a fresh install, the maintainer asked to set a hotkey right where a tool is selected in Toolbox ("Set" or change it, in its own block at the very top, Action smaller), and called the selected-tile look (a thick blue rounded rectangle around circle and caption) ugly.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Settings/ToolboxHotkeyBlock.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Hotkeys/HotkeyRecordingSession.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Hotkeys/ToolShortcutAssignment.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Settings/ToolboxSettingsView.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/Settings/ToolboxHotkeyBlockTests.swift
    confirmed_at: 2026-11-22
related: [2026-10-20-toolbox-mini-apps.md, 2026-10-18-toolbox-drag-feedback.md, 2026-11-20-toolbox-system-background.md]
---

# Context

Tool shortcuts lived only in Settings -> Hotkeys -> Tools, behind a draft and
Save. In Toolbox the user selects a tool and sees its settings, but had to go
to another tab to give it a key. The selected tile drew an accent stroke on its
circle, and because the tile was `.focusable()`, a click also gave it keyboard
focus, so macOS drew its thick focus ring as a rounded rectangle around circle
and caption. That rectangle was what looked crude.

# Decision

- The right pane pins the tool's title row and a **Hotkey block** above the
  tool's own panel (only the panel scrolls). No shortcut: **Set**. A shortcut:
  its keycaps, **Change** and a remove button. Recording shows the live keys
  and "Press a shortcut, then release all keys. Esc cancels." Record's block is
  "Extra hotkey" (Meeting record keeps its own shortcut in Hotkeys).
- The block saves at once through `HotkeyPreferences.assignToolShortcut`,
  which builds the configuration with only that tool changed and calls
  `apply`, the Hotkeys Save path. A conflict saves nothing, names the other
  owner ("Shortcut ⌥ Q is already used by Agent close and Notify.") and keeps
  recording open for another key; hold-Space stays Drop's. Hotkeys shows the
  change immediately (its draft follows the saved configuration while it has
  no unsaved edits), Help and the island hints read the same configuration.
- `HotkeyRecordingSession` is the one recorder for both places: the local key
  monitor, `HotkeyShortcutRecorder`, Escape to cancel and the
  `hotkeyRecordingActive` gate that pauses global hotkeys.
- The Action pane is compacter: smaller title icon, 10 pt spacing, and the
  viewport's minimum content height is 260 pt instead of 330 pt, so the
  Hotkey block and the start of the tool fit at the minimum Settings size.
- **Selected tile:** an accent wash (20 %) fills the circle, the symbol turns
  accent and the caption becomes semibold in the label color; no outline. Tiles
  use `.focusable(interactions: .activate)`: like native buttons they are
  reached by keyboard navigation and are never focused by a click, and
  `ToolboxTileFocusShape` gives the system focus ring the circle's shape.

# Why

Saving at once fits a single-key change made beside the tool; the full Hotkeys
tab keeps its draft for bulk edits. Routing through `apply` keeps one place for
persistence, conflicts and re-registration. Pinning the block above the
scrolling panel meets "at the very top" without growing the window.

Selection variants (offscreen renders, light and dark): **wash** (chosen),
**ring** (accent ring outside the circle) and **solid** (accent fill, white
symbol). DESIGN.md asks for label-color text on an accent wash for selected
tools (Screenshot toolbar) and keeps keyboard focus a separate ring. The ring
variant would look the same as the focus ring, and the solid fill reads like an
"on" state (Record lit while recording). The wash keeps selection, keyboard
focus and the added-to-hover check visually distinct; the semibold caption
means it is not shown by color alone.

# What was checked

- `ToolboxHotkeyBlockTests` (13): a Toolbox hotkey is saved, read by
  `configuration` (the Hotkeys draft and Help), and survives a new store on the
  same defaults; changing replaces only that tool; a tool/tool and a core
  (Agent close) conflict are reported and change nothing; removing clears it;
  hold-Space is refused; the shared recorder commits on release, consumes keys,
  pauses global hotkeys and cancels on Escape; conflict-then-free-key flow;
  the block is pinned above the viewport; both views use the shared recorder;
  the tile uses the wash and the circular focus shape.
- Offscreen renders (`WHYTAP_TOOLBOX_HOTKEY_RENDER_DIR`): the whole Toolbox at
  the minimum content size with and without a hotkey, and every block state,
  light and dark.
- Not checked: the live focus ring with keyboard navigation on, a real click
  not focusing a tile, VoiceOver, and the installed app.

# Rejected

- A second copy of the recorder in Toolbox: two places would drift.
- A draft with Save in Toolbox: an extra step for one key.
- Ring or solid selection: see Why.
- Hiding the focus ring entirely: keyboard users need it.

2026-11-22 · branch claude/toolbox-hotkey-selection-7f9ebc
