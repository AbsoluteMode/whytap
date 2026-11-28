---
id: agent-all-hotkeys-2026-11-28
type: decision
title: The Agent and coding tools read and change every Whytap hotkey and its mode
summary: whytap_hotkeys_get lists every hotkey; whytap_hotkey_set with a hotkey id sets any key Settings accepts, Hold/Toggle or a reset, and returns bound/previous/undo/takenEverywhere through the Features rules and HotkeyPreferences.apply. Settings rows no longer share one accessibility name.
status: confirmed
tags: [agent, native-agent, app-control, hotkeys, mcp, accessibility]
canonical_for: [agent-all-hotkeys]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: "On 2026-11-28 the maintainer asked that the agent can change every hotkey to available keys and switch hotkey modes through the Whytap MCP server, after Codex could not put dictation back on hold Space (orchestrator task 114)."
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/AppControl/AppControlHotkeys.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/AppControl/AppControlHotkeysTests.swift
    confirmed_at: 2026-11-28
related: [2026-11-22-agent-toolbox-hotkeys.md, 2026-11-24-settings-around-features.md]
---

# Every hotkey from the Agent and coding tools

## Context

The maintainer asked Codex, with the Whytap MCP server connected, to put
dictation back on hold Space. `whytap_hotkey_set` only assigned island-tool
hotkeys, so Codex said the dictation hotkey is not available over MCP, tried
Settings → Hotkeys with Computer Use and gave up; Drop stayed Toggle on the
`` ` `` key. The built-in Agent refused too.

The Computer Use attempt failed on Whytap's side: each Settings → Hotkeys row
put `accessibilityLabel("<row> shortcut")` on the stack holding its mode
button and key caps, and SwiftUI copied it onto both buttons. Automation saw
two "Drop voice shortcut" buttons, its click on one failed with "multiple
elements were found that match the criteria", and each key cap alone was
"Shortcut key". VoiceOver users heard the same ambiguity.

## Decision

- **One read, one write.** `whytap_hotkeys_get` (new, read-only) lists every
  Settings → Hotkeys row by a stable id, every tool as `tool.<id>` and the
  fixed global keys (Help ⌥H, Escape closing the answer), with keys, display,
  mode, allowed modes, changeable, clearable and default.
  `whytap_hotkey_set` keeps its tool form unchanged and gains `hotkey`, `mode`
  and `reset`. A second write tool would have duplicated the expected-value
  and conflict contract; the native Agent gets both through its one strict
  `whytap` tool, so the strict-schema limits are unchanged.
- **The Settings rules, not a copy.** The write applies the row's change with
  `FeatureHotkey.assign` / `setGesture` (the Features screen's own rules:
  Space is Drop's alone; it forces Hold; Toggle is refused on Space) and saves
  through `HotkeyPreferences.apply`, the Hotkeys Save path. Its conflict model
  (one physical key = one action, the modifier tap/hold split) refuses
  conflicts, and the monitors re-register from the published preferences as
  after Save. A refusal names the other action and the nearest free ⌃/⌥ keys.
- **Any key Settings accepts (owner's correction, same day).** The first
  version kept the 2026-11-22 tool rule for every row: only ⌃/⌥
  combinations, bare F-keys, the right modifiers and Space, so a misread
  request could not take ⌘C or a letter. The maintainer's first real request
  on that build, "change Drop in Whytap to `", was refused: a bare backquote
  was not available over MCP, the agent could not finish it in Settings, and
  it sent him to Settings → Hotkeys himself. He had used ` for Drop before.
  His requirement: the agent changes every hotkey to any available key and
  switches its mode, and "available" means what Settings itself accepts. So
  `whytap_hotkey_set` with `hotkey` parses exactly what the recorder records
  (any modifiers or none + one recorder key, a right modifier alone, Space
  alone for Drop) and applies Settings' own per-row gates and conflicts; it
  has no rule of its own. Tools too, through `hotkey: tool.<id>` (Quit and
  coming-soon tools, as Settings → Hotkeys → Tools allows).
- **A mistake is cheap instead of forbidden.** The reply states `bound` (keys
  and mode now), `previous` and `undo` (the arguments that restore them in
  one call), and `takenEverywhere` for keys other apps lose: a bare typing
  key, Tab or Delete grabbed through Carbon ("` … no longer types “`”"),
  Shift-only and Command(+Shift) combinations. A hold Drop on a bare key is
  the exception and says so: `SpaceHoldMonitor` without required modifiers
  uses the Space policy, passing the key through and erasing it when the hold
  arms in a text field, so a quick press still types it (checked in code and
  by a monitor test). The descriptions tell the model to relay that line.
- **The older `tool` form keeps its rule for now.** `whytap_hotkey_set` with
  `tool` still takes only ⌃/⌥ combinations; its refusals point to
  `hotkey: tool.<id>`. The built-in agent's tests pin that form, and their
  file is deleted by the harness stack (#529, #544); changing them here would
  block the combined owner-local build. Drop the rule once that stack lands.
- **No clear for actions that must have keys.** Settings has no clear button
  on these rows; only tool hotkeys clear. `reset` restores the default keys
  and mode.
- **No new Yes.** Like settings, models and tool hotkeys, hotkeys are not
  behind the per-harness Yes: they hold no user content, the request is the
  user's, the agent shows a line for each saved change, and Settings shows it.
  The guide claimed tools and hotkeys needed the Yes; the code never gated
  them, and the guide now says so.
- **Accessibility.** Each row's mode button is "<row> mode" with the mode as
  its value. The key caps form one button "<row> shortcut" with the spoken
  keys as value and Record as action.

- **Built-in agent: catalog only.** The built-in Agent reads its operations
  from the MCP catalog, so it gets both without its own code. Its file
  (`NativeAgentAppControl.swift`) is left unchanged: the harness stack
  (#527–#529, #544) deletes it, and an edit there would block the combined
  owner-local build. Until that stack lands, its progress label for
  `whytap_hotkeys_get` falls through to "Reading a meeting" and its change
  line has no mode (`Hotkey: Drop voice — Space`).

## Rejected

- A separate `whytap_hotkey_change` tool: duplicates `hotkey_set`'s contract
  and adds a catalog entry for the same Settings action.
- An agent-only key rule (⌃/⌥ only, no bare typing keys): shipped first and
  dropped the same day after it refused the maintainer's "set Drop to `".
- Pairing `expected` with the mode: the keys guard catches a concurrent
  rebind, and the mode is an absolute value that is safe to repeat.
- Listing window-local keys (screenshot editor, Case prompt, History): they
  are not hotkeys of the Mac and no screen changes them.

Date: 2026-11-28. PR: see the branch `feature/mcp-all-hotkeys`.
