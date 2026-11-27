---
id: agent-toolbox-hotkeys-2026-11-22
type: decision
title: The Agent and the plugin change the island's tools and their hotkeys
summary: whytap_toolbox_get/set and whytap_hotkey_set pin, move or remove island tools and assign tool hotkeys through the Settings stores, with the link hotkey rule and refusal on conflict.
status: confirmed
tags: [agent, native-agent, app-control, toolbox, hotkeys, mcp]
canonical_for: [agent-toolbox-hotkeys]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: "On 2026-11-22 the maintainer asked whether the agent can add or remove something in the menu, for example Shot, and assign it a hotkey right away, then said: yes, teach it (orchestrator task 53)."
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/AppControl/AppControlToolbox.swift
    confirmed_at: 2026-11-22
  - type: commit
    reference: 6bc1cd8a2cf73736c77492a800309246f552092f:Tests/SidekeyTests/AgentDaemon/NativeAgentAppControlTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-native-agent-app-control.md, 2026-10-21-app-control-plugin.md, 2026-11-23-agent-drop-lists.md]
---

# Island tools and hotkeys from the Agent and the plugin

## Context

The Agent in the island and the plugin's `whytap mcp` could change models,
settings and To-do, but not which tools the island shows or their hotkeys:
`get_settings` told the model that hotkeys cannot be changed. "Add Shot to the
menu and give it ⌥S" had to be done by hand in Settings → Toolbox and
Settings → Hotkeys.

## Decision

- **Three operations in the one catalog.** `whytap_toolbox_get` (pinned order
  plus every tool with id, title, description, pinned, position, comingSoon,
  hotkey `{keys, display}` and hotkeyAssignable), `whytap_toolbox_set`
  (`tool`, `pinned`, optional `position`, `expected` pinned list) and
  `whytap_hotkey_set` (`tool`, `keys` or null, `expected` current keys or
  null). They are added to `AppControlMCPServer.tools`, so the plugin gets
  them as MCP tools and the native Agent as operations of its single strict
  `whytap` tool (no new strict tool, union or optional parameter; the
  first-request limit test checks Anthropic, OpenAI and OpenRouter).
- **Settings' own stores.** Pinning and moving use `HoverLayoutStore.placeTool`,
  removing `removeTool`: the island and Settings → Toolbox observe that store
  and change at once; Settings stays last and cannot be moved or removed.
  Hotkeys go through `HotkeyPreferences.assignToolShortcut`, the Hotkeys Save
  path (`apply`) shared with the Toolbox Hotkey block of session 69: one
  conflict check, persistence and registration. The Hotkeys pane follows a
  saved change when its draft was clean. No UserDefaults write of its own.
- **Which keys.** The `whytap://hotkey` rule (`WhytapLink.linkCombo`,
  `acceptsLinkHotkey`): Control or Option plus A–Z, 0–9, F1–F20 or US
  punctuation; no Quit, no "Soon" tool. A model writes key names, it does not
  press keys, so ⌘ and ⇧ shortcuts that macOS and other apps own are never
  reachable by a misread request. Settings' recorder stays the way to set any
  other key.
- **Conflicts and refused keys.** Keys used by another action (Agent close
  ⌥Q, another tool…) are refused as `hotkey_conflict` naming that action;
  nothing is taken over or cleared. Both that and `invalid_hotkey` (⌘F) name
  the nearest free keys the rules accept: the same key with ⌥, ⌥⇧, ⌃⌥, ⌃⇧ or
  ⌃. The prompt tells the Agent to give the reason and that choice and ask.
- **Typed characters.** An Option combo is allowed but types a character in
  text fields (⌥F types the florin sign on US); a global hotkey takes it. The reply carries
  `typesInTextFields`, read from the current keyboard layout with
  `UCKeyTranslate` (dead keys: "its ⌥ accent"), and the line warns once:
  `(no longer types “<character>” in text fields)`.
- **Words.** The descriptions and prompt call them the island's hover tools,
  quick actions, Toolbox or menu, and say "option f" means option+f, so
  "add Shot to my quick actions (hover) and set the hotkey option f" (the
  maintainer's acceptance request, asked in Russian) maps to these operations.
- **Suggesting Whytap's tools (maintainer: "only suggest").** Build 1712
  answered "can you take a screenshot of my screen?" with a capture it could
  not save and macOS's Shift-Command-3/4. The Agent prompt now says Whytap's
  own tools come first: for a task a tool may do it reads
  `whytap_toolbox_get`, chooses by the titles and descriptions there
  (`HoverToolRegistry`, so no invented tool) and suggests the tool with its
  current hotkey ("Press ⌥S — that's Shot"). Without a hotkey it points to the
  island's hover (pinned) or the hover's search and offers to pin it or set a
  hotkey, changing nothing until the user agrees. It does not recommend
  Shift-Command-3/4 for what Whytap does and never uses `capture_screen` to
  take a screenshot for the user. No operation opens or starts a tool; the
  catalog still has none.
- **Expected values.** Every write needs the exact current value: the pinned
  list for the Toolbox, the tool's keys (any modifier order) for a hotkey. A
  stale value is a `conflict`.
- **Visible changes.** Lines from the saved result: `Toolbox + Shot`,
  `Toolbox − Monitor`, `Toolbox: Monitor → place 1`, `Hotkey: Shot — ⌥S`,
  `Hotkey: Shot — none`. A hotkey for a tool added in the same turn joins its
  line: `Toolbox + Shot · ⌥F (no longer types “<character>” in text fields)`. A repeated identical request answers
  `changed: false` and shows no line.

## Why

- The same stores as Settings keep the island, Settings, Help and the
  registered shortcut consistent and avoid a second validation that could
  drift from the Hotkeys pane.
- The link rule is the reviewed safe subset for keys chosen without a key
  press; reusing it keeps one definition of "safe to assign remotely".
- Refusing conflicts keeps the user's existing shortcuts; silently moving them
  would break muscle memory with no visible cause.

## What was tested

`NativeAgentAppControlTests` with the real native loop, a stubbed model and
the real controller on temporary stores: the acceptance request word for
word ("quick actions (hover)", "option f": Shot pinned, ⌥F saved, one line with
the florin-sign warning, the words present in the tool description and prompt); keys
refused for ⌘ and owned by Agent close, each naming the nearest free keys;
which combos type a character; "add Shot and set ⌥S" (layout and
shortcut saved, two lines, a fresh store reads both, the shortcut resolves to
a registration); "remove Monitor" (gone from the layout, its hotkey kept);
moving a tool to place 1; conflicts with Agent close and with another tool
(nothing changed, owners named); repeating the request (no change, no line);
unknown tool, Settings removal, stale expected values, a bad position, Quit
and Calendar (Soon), ⌘/⇧/Space keys and wrong types; clearing with the keys in
another order. The first request on Anthropic, OpenAI and OpenRouter stays
within the strict limits and its operation enum has the three operations.
The screenshot request from build 1712: one `toolbox_get` read, no change
line or store change, Shot's registry description and hotkey in the read,
and the rule in the system prompt; the read lists every registry tool with its
own description and an unassigned Shot as unpinned without a hotkey; no
operation opens, starts or captures. These check what the model receives,
not what a live model answers.
`AppControlMCPServerTests` lists the three MCP tools with their annotations
and forwards a call. Not tested: the installed app, a live provider.

## Rejected

- Writing `toolShortcuts` / the layout defaults directly: bypasses
  registration, conflict check and the published stores.
- Accepting any recorded combo (⌘, ⇧, arrows): a misread request could take
  ⌘C or ⌘Q system-wide.
- Taking over or clearing a conflicting action's keys: surprising and silent.
- A tool-only expected value for `toolbox_set`: the position meaning depends
  on the rest of the list, so the whole pinned list is compared.

2026-11-22, branch `claude/agent-toolbox-hotkeys`.
