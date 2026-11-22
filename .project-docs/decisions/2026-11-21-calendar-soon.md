---
id: calendar-soon-2026-11-21
type: decision
title: Calendar is closed behind one switch and shown as Soon
summary: Calendar stays visible with a Soon badge but cannot be opened, connected or read; one constant in CalendarAvailability reopens it and no Calendar code was removed.
status: confirmed
tags: [calendar, availability, soon, hover, settings, hotkeys]
canonical_for: [calendar-soon]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the maintainer asked, through the orchestrating session, to close Calendar for now because a collaborator is still reworking it; users must see it marked Soon but not be able to enable or use it, the code must stay, and the lock must be removable in one change. The new onboarding must not offer Calendar either.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarAvailability.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Planner/CalendarSoonTests.swift
    confirmed_at: 2026-11-21
related: [2026-11-22-calendar-release.md, 2026-10-21-calendar-hover.md, 2026-10-21-calendar-integrations.md, 2026-11-20-calendar-day-view.md, 2026-11-21-calendar-logos.md, 2026-11-21-calendar-event-details.md]
---

# Calendar is Soon

> **Lifted 2026-11-22.** The collaborator's work is in main and the maintainer
> released Calendar: `CalendarAvailability.shipped` is now `true`. The switch and
> every gate below stay, so `false` closes Calendar as Soon again in one edit.
> Why and what was checked: [Calendar is released](2026-11-22-calendar-release.md).

## Context

Calendar (the Hover day view, Settings -> Integrations -> Calendars, the Google,
Outlook, Apple and Zoom connections) is being reworked by a collaborator. Until
that lands, users must not be able to turn it on, and nothing may ask macOS for
calendar access. The collaborator keeps working on the same code and must be able
to ship it again with one edit.

## Decision

`CalendarAvailability.shipped` (`Sources/Sidekey/Planner/CalendarAvailability.swift`)
is the single switch. It is `false`, so Calendar is "Soon":

- **Visible, inert.** The Calendar tile (Hover, Toolbox catalog), its hover-search
  row and Toolbox pane carry a "Soon" badge. The Settings -> Integrations Calendars
  section is one card with a "Soon" plaque and a disabled Connect button.
  Calendar's Hover controls give no active hover or press feedback and do not
  claim first mouse.
- **One router gate.** `HoverSlotRouter.effect(for:)` returns `.comingSoon` for a
  closed tool. The tile, search, Toolbox and tool-hotkey paths all end there; the
  island also refuses a programmatic `.calendar` panel request.
- **Hotkeys and links.** A saved Calendar tool shortcut is kept but never
  registered, so it does not capture the key. Help omits it. `whytap://tool/calendar`
  shows the Toolbox pane; `whytap://hotkey/calendar` only opens Settings -> Hotkeys.
- **Engine gate.** `CalendarConnections` refuses `beginConnecting`, `add` and
  `enableApple` (it never creates an `EKEventStore`, so macOS shows no prompt) and
  `refresh*` return without a provider request or EventKit read. The connect flow and
  the Hover model refuse to start. A user who was connected before sees and gets
  nothing, and no sign-in, refresh or update-restart hold runs in the background.
- **Data is kept.** Stored accounts, Keychain credentials, the Apple flag, hidden
  feeds, backups and settings sync are untouched, so reopening restores them.
- **Onboarding and new surfaces** must ask `CalendarAvailability.isOpen` or
  `HoverTool.isComingSoon` and not offer Calendar while it is closed.

To reopen Calendar: set `shipped = true` (done on 2026-11-22). `CalendarSoonTests`
closes the switch with `closeCalendarForThisTest()` and keeps checking the closed
state; to close Calendar again set `shipped = false`.

## Why

A switch in the code that every entry point consults keeps the collaborator's
branch mergeable: nothing was deleted or moved, so the reopening edit is one line.
Putting the gate in `HoverSlotRouter` and the engine rather than in each view means
a path added later (hotkey, link, onboarding) is closed by default, while the badge
rendering stays cosmetic. Settings values are left alone because a user's
connections took effort to create and the switch is temporary.

## What was tested

`CalendarSoonTests` runs with the real default: closed flag, router and hotkey
bindings, links, Settings card, refusal to connect or enable (Apple never asked, no
provider request), a user with stored connections doing nothing yet keeping their
saved data, and reopening reading those connections again. The existing Calendar,
Planner, Backup and Hotkey tests open Calendar for one test through the override.

## Rejected

- **Hide Calendar entirely.** The maintainer asked for a visible "Soon".
- **Delete or `#if` out the code.** The collaborator keeps working in it.
- **Clear stored connections.** Reopening would force everyone to reconnect.
- **Gate only in views.** A future entry point would bypass it.

2026-11-21, PR: see the pull request that added `CalendarAvailability`.
