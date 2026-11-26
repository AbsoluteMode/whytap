---
id: notifications-in-notify-2026-11-26
type: decision
title: Notification settings live only on Features → Notify; the Notifications tab is gone
summary: The Notifications tab under General repeated the source list of the Notify screen. It is removed; its id stays, like agentMode, so links, What's new and Lil Bro answers that name it open Features → Notify.
status: confirmed
tags: [settings, features, notify, notifications, links, lil-bro]
canonical_for: [notifications-settings-place]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the maintainer asked why notifications sit under General (Other) when there is the Notify feature (ORCH-TASK 114, translated); the task was to remove the duplicate and lead every old way in to Features → Notify.
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsWindowTab.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Settings/NotificationSourcesGroups.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/Settings/SettingsWindowTabTests.swift
    confirmed_at: 2026-11-26
related: [2026-11-24-settings-around-features.md, 2026-11-24-hover-notify-monitor-screens.md, 2026-10-20-whytap-links.md, 2026-11-24-lil-bro.md]
---

## Context

When Settings was rebuilt around features, Notify got its own screen
([decision](2026-11-24-hover-notify-monitor-screens.md)) with the same
source list (`NotificationSourcesGroups`) the older Notifications tab showed.
The tab stayed as a row of General → More. The two places showed one list:
the built-in Meeting notes source and the connected sources, each with its
switch and sound. The maintainer asked why notifications were under General
at all when Notify exists.

## Decision

- General no longer has a Notifications row, and the tab's view is deleted.
  Every notification setting is on Features → Notify.
- `SettingsWindowTab.notifications` stays as a case, exactly as `agentMode`
  did when the Agents tab became the Agent's screen: it is not selectable
  (`availableCases`), resolves to Features and opens Notify's screen
  (`featureScreen`). `whytap://settings/notifications`, a What's new button
  with `"settings": "notifications"` and saved links keep working.
- A Lil Bro answer from whytap.ai that names a former tab
  (`notifications`, `agentMode`) becomes that feature's destination, so he
  runs to Notify's or the Agent's screen instead of stopping on the
  Features list.
- Texts that sent people to "Settings → Notifications" (backup restore notes,
  the Meeting Notes switch) now name Notify.

## Why

One list in two places makes people wonder which one counts. Notify's
screen already had everything the tab had, plus the shortcut and the way to
connect a source. Keeping the id costs one enum case and keeps every link
that was ever handed out working; removing it would turn those links into
"show the island" (an unknown tab).

## What we tested

- The Notify screen shows the built-in Meeting notes source with its sound
  control and switch and the connected sources: it renders the same
  `NotificationSourcesGroups` view the tab did; the only text the tab had
  that the screen lacked ("clicking a meeting card opens its notes") was
  added to the screen's footnote.
- Unit tests: the old tab id opens Notify from a selection, a link and a
  highlight; General's More rows are Backup and Integrations; Lil Bro maps
  former tabs to their features.

## Rejected

- Deleting the case: old links, What's new entries and site answers naming
  `settings/notifications` would land nowhere.
- Keeping the tab and hiding the row: a second, unreachable copy of Notify.

2026-11-26 · ORCH-TASK 114
