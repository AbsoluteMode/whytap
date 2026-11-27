---
id: hover-notify-monitor-screens-2026-11-24
type: decision
title: Hover, Notify and Monitor get feature screens; Notify and Monitor hand a coding agent a ready prompt
summary: Hover, Notify and Monitor join the Features list with their own screens. Hover lists the island's tools in the island's order; a tool is held and dragged to a new place and switched off or on, straight in the layout the island observes. Notify and Monitor show what is connected and a Copy prompt card with the marks of Claude Code, Codex, Cursor and Antigravity; the prompt carries this Mac's real paths and the contracts the app enforces.
status: confirmed
tags: [settings, features, hover, toolbox, notify, monitor, coding-agents]
canonical_for: [hover-feature-screen, agent-copy-prompt]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24 the maintainer asked for the whole Settings rework at once (ORCH-TASK 103). About Hover he said he liked that the tools were taken out, that in Hover a tool could be held and swapped, and that a toggle switches off one that is not needed (translated). About Notify and Monitor he asked for something like a copy prompt for Claude Code or Codex, with the logos of the models, and then added that Cursor and Antigravity can be included too (translated).
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Settings/Features/HoverFeatureView.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Settings/Features/CodingAgentPrompt.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/Settings/HoverFeatureTests.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/Settings/NotifyMonitorFeatureTests.swift
    confirmed_at: 2026-11-24
related: [2026-11-26-notifications-in-notify.md, 2026-11-26-every-feature-in-features.md]
---

## Context

Settings is being rebuilt around features
([decision](2026-11-24-settings-around-features.md)); Drop got the first
screen. The island's tools were chosen in Toolbox, a two-pane drag-and-drop
editor with a catalog of tiles; Notify's sources lived in the Notifications
tab and Monitor had no settings page at all. Connecting a notification
source or a dashboard already worked through a coding agent, but the person
had to know that and tell the agent where Whytap's files are.

## Decision

- `AppFeature` gains `hover`, `notify` and `monitor`, listed after
  Screenshots, each with its own screen (`FeaturePlace.screen`). They need no
  key, model or permission.
- **Hover** is always Ready. Its screen lists the tools "In the island" in
  the island's order (left to right, row by row), Settings pinned last, then
  "More tools" that are off, in the catalog order.
  - (Replaced on 2026-11-25: the list is no longer dragged; tools are
    reordered by holding a tile in the island itself, see
    [island hover reorder](2026-11-25-island-hover-reorder.md).) Originally
    a tool was held by its row and dragged, with live moves and drops on
    More tools.
  - Each row has a switch: off takes the tool out of the island, on puts it
    back at the end, before Settings. Move Up, Move Down and Move to Top are
    in the row's context menu and VoiceOver actions.
  - Every change goes to `HoverLayoutStore`, which the island observes and
    which survives a restart. Settings cannot be dragged or switched off.
  - The chevron opens the tool's shortcut (the Toolbox `ToolboxHotkeyBlock`:
    Set, Change, Remove) and the way to its own settings: Notify's and
    Monitor's screens, Translate & Subtitles, Screenshots, Drop, or the
    tool's Toolbox pane. A tool that is off keeps its shortcut and stays in
    island search.
- **Notify** and **Monitor** are "Not set up" (quiet, counted nowhere) until
  the person's agent connected a source or a dashboard, then Ready. The
  built-in Meeting notes source belongs to Meeting Notes and is not counted.
- The three screens share the feature header, scrolling layout and quiet
  clip slot used by Drop.
- Their screens: what it does; the tool's shortcut and an Open button for its
  island panel; the sources (the Notifications tab's list, now one shared
  view) or the dashboards with how fresh each is; and a "Let your coding
  agent set it up" card with the marks of Claude Code, Codex, Cursor and
  Antigravity, Show prompt and Copy prompt. With nothing connected the card
  comes first.
- The prompt is one text for every agent. It is built from the paths this
  Mac uses (`NotifyPaths`, the Monitor store's root) and the contracts the
  app enforces: for Notify, the guide the app writes (`README.md`), the
  manifest and line format, allowed links and verification in
  `history.json`; for Monitor, the snapshot fields, widget kinds, limits,
  atomic writes, the optional `servers.json`. It forbids sending messages,
  LaunchAgents for Notify, changing servers and putting secrets in files.
- Settings rereads Monitor's files every five seconds while the Monitor
  screen is open. The store is never started, so Settings never connects
  to servers. An unreadable server configuration is shown for repair and
  does not count toward Ready. Copying goes through
  `FeaturesEnvironment.copyText`; tests pass a box, never the pasteboard.
- The Toolbox and Notifications tabs stay until the sidebar is reduced.

Builds on [Settings around features](2026-11-24-settings-around-features.md),
[the Toolbox tool hotkey](2026-11-22-toolbox-tool-hotkey.md),
[script notifications](2026-10-19-script-notifications.md) and
[optional Server status](2026-11-23-monitor-server-status-optional.md).

## Why

- Maxim liked the tools on their own page and asked for hold-and-drag and a
  toggle; a list says what each tool does, which the tile grid did not.
- Live reordering shows where the tool lands before it is let go; the island
  changes at the same moment because it observes the same store.
- A prompt with the real paths removes the step the person could not know.
  Building it from the same constants the app reads means it cannot point
  somewhere Whytap does not look; the tests write a manifest and a snapshot
  the way the prompt says and check that the app accepts them.
- A source or dashboard that does not exist is not something to report as a
  problem, so the unconnected state is quiet, like an unused island tool.

## What we tested

`HoverFeatureTests`: the row opens the screen; the list covers every tool
once; switching off and on, all tools off, persistence after a restart; a
tool keeps its shortcut when off; dragging up and down with live moves; no
flip-back when a row slides under the pointer; a tool that is off dropped
into the island; dropping on Settings and on More tools; Settings not
draggable; a drop without a drag and a drag left mid-way change nothing;
Move Up, Down and to Top with bounds; offscreen pictures in both themes at
960 and 1280 points and with every tool on.

`NotifyMonitorFeatureTests`: both rows open their screens; Not set up with
nothing connected and Ready with a source or a dashboard; Copy prompt puts
the prompt on the (test) clipboard and says Copied for a moment; every agent
has its bundled mark; the Notify and Monitor prompts carry this Mac's paths,
the allowed links, the widget kinds and the safety lines; a manifest and an
event line written the way the prompt says are accepted; a snapshot written
atomically appears with its freshness and makes Monitor Ready; Server status
is listed only once `servers.json` names a server, without connecting;
offscreen pictures of both screens empty and connected.

Not checked in a running app: a real drag with the pointer (the drop
delegate's calls are covered through `HoverToolDragModel`), the island
redrawing during a drag, pasting the prompt into each of the four agents.

## Rejected

- Reordering only in the island itself (the mockup's note): at first Maxim's
  words were read as hold-and-drag in Settings; on 2026-11-25 he clarified he
  meant the island, and that change was made
  ([island hover reorder](2026-11-25-island-hover-reorder.md)).
- One list without "More tools": the order of tools that are off would need a
  second stored order the island never uses.
- A prompt per agent: the agents read the same files; one prompt avoids four
  texts drifting apart. The marks say which agents it was written for.
- An Antigravity mark in colour: the other marks are monochrome templates;
  ours is the arch of its icon, from the harness logo in Whycode.

2026-11-24, ORCH-TASK 103.
