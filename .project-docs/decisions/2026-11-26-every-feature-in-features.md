---
id: every-feature-in-features-2026-11-26
type: decision
title: Every feature is in Features, with its settings on its own screen
summary: Display, History and Calendar, until now only island tiles, get rows and screens in Features. Settings that belonged to one feature but lived far from it move to that feature's screen without staying behind - Smart's output language to Drop, the Agent's link keys to the Agent, the calendars from Integrations to Calendar, Hold brightness, Extra and Brightness keys from Toolbox to Display. Integrations keeps GitHub and Coding tools.
status: confirmed
tags: [settings, features, display, brightness, history, calendar, drop, agent]
canonical_for: [features-list-completeness]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the maintainer looked at Settings → Features (11 rows) and asked why not every feature is there, "turning on extra brightness now takes a hell of a path" (translated), then "make it so every feature is in Features and every setting it needs is at hand" (translated). ORCH-TASK 116.
    confirmed_at: 2026-11-26
  - type: user-confirmed
    reference: The same day, on the plan, he answered that Coding tools (access of Claude Code and Codex) "can stay in Integrations, like installing the MCP" (translated).
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Settings/Features/FeatureCatalog.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/Settings/EveryFeatureInFeaturesTests.swift
    confirmed_at: 2026-11-26
related: [2026-11-24-settings-around-features.md, 2026-11-24-hover-notify-monitor-screens.md, 2026-11-26-notifications-in-notify.md, 2026-10-18-brightness-tool.md, 2026-11-23-calendar-macos-only.md]
---

## Context

Settings → Features listed 11 features. Display (brightness with Extra),
History (clipboard history) and Calendar were island tiles only: Extra was
reached through Features → Hover → the Display row → Open in Toolbox → the
Display pane, and the calendars through General → More → Integrations. Some
settings of listed features also lived elsewhere: Smart's output language
only in the island (Output Lang), the four keys of the links under an Agent
answer only in Hotkeys.

## Decision

- `AppFeature` gains `history` (tool History), `display` (tool Display) and
  `calendar` (tool Calendar), listed after Screenshots and To-do. Each is an
  island tool on the screen template: no switch (the card points to
  Toolbox), its Open shortcut, a "Use it" row that opens the island panel.
- **Display**: Hold brightness, Extra and Brightness keys
  (`DisplayBrightnessSettings`, formerly `ToolboxDisplayPane`). Toolbox's
  Display pane keeps only "Open Display settings". What it needs: Keyboard
  control, optional, for Brightness keys only. Always Ready.
- **History**: no settings of its own exist, none were invented. Always Ready.
- **Calendar**: the Calendars card (`SettingsCalendarIntegrationsView`) moves
  here from Integrations. Ready once it shows a calendar (the card's own check:
  macOS allows reading and the list has a calendar, or an account an earlier
  build connected), otherwise quietly Not set up; never Ready while Calendar is
  closed as Soon. Features Home rechecks access and the list on appear and on
  activation, without a prompt or an event read.
- **Drop** gets "Language Drop writes in" (Smart's output language, the same
  preference as Output Lang; As spoken is no translation). The open screen
  follows a change made in the island.
- **Agent** lists its link keys (Paste the chosen link, Open the chosen link,
  Next link, Previous link) among its shortcuts, saved in the same fields as
  Hotkeys.
- **Integrations** keeps GitHub and Coding tools (Claude Code and Codex access
  to Whytap's MCP server): installing an integration, not a feature.
- Hover's row chevron leads each tool to its feature's screen: Display,
  History, Calendar, To-do, Case; Drop's tiles (mode, Vocab, Filler,
  languages) to Drop; Record and Notes to Meeting Notes. Only tools without a
  feature (Hotkeys) still go to Toolbox.
- Hotkeys stays as the one place that shows every shortcut and its conflicts;
  feature screens show their own, as before.

## Why

- A feature a person can name, with no row in Features, is found only by
  someone who already knows where it is. The three tiles are features in
  everything but the list.
- One setting in one place: the moved rows are removed where they were, as
  with Notifications in Notify.
- Two clicks from Features to any setting of a feature: the row, then the
  setting on its screen.

## What we tested

`EveryFeatureInFeaturesTests`: the three features, their places, tools and
Open shortcuts; every island tool that is a feature has a row; Display and
History Ready on a fresh Mac and Display's optional Keyboard control with its
sentence; Calendar Not set up, Ready with a calendar, Not set up while closed;
the calendar check (access taken back, an old account); the live snapshot
from a fake EventKit only; the Agent's link keys read and saved in the
Hotkeys fields, a key in use refused; Drop's output language words; Hover
leading tools to features; each screen opening from the list; pictures of the
new screens, Drop and the Agent in both themes, usual and fresh.
`FeatureCatalogTests` covers the 14 rows and their fresh-install statuses.
That the moved rows are gone from Toolbox and Integrations was checked in the
code and the pictures, not by a test.

The builder's review of ticket 667 found Calendar Ready with access taken
back or zero calendars (the saved opt-in counted as a calendar) and an open
Drop screen keeping an old output language; both are covered by
`FeaturesRelocationRegressionTests`, the builder's reproducer.

Not checked in a running app: Extra on a real XDR display from the screen,
the calendars card's macOS prompt from its new place.

## Rejected

- A Coding tools / MCP feature: the maintainer chose to keep it in
  Integrations as installing an integration.
- Output Lang, Vocab, Filler, Input Lang, Drop Mode, Record and Notes as
  features: they are settings or actions of Drop and Meeting Notes.
- Leaving the brightness switches in Toolbox as well: two places for one
  switch.
- A pointer row "Calendars moved" in Integrations: one more row to keep.

2026-11-26 · ORCH-TASK 116
