---
id: calendar-logos-2026-11-21
type: decision
title: Calendar events carry their service's logo and Hover shows every calendar
summary: Event blocks are one colour with a small logo of their service; calendar hiding, the calendar list page and the Refresh button are gone, the day switcher is compact and Connect rows carry provider logos.
status: confirmed
tags: [calendar, hover, planner, design]
canonical_for: [calendar-logos]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user asked to remove the calendar filter and the refresh button, make the main buttons narrower, add logos to the Connect list, drop calendar hiding entirely and show a small logo on each event instead of each calendar's colour.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarSourceLogo.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarHoverView.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Planner/CalendarDayViewTests.swift
    confirmed_at: 2026-11-21
related: [2026-11-20-calendar-day-view.md]
---

# Calendar logos instead of colours

## Context

The day view from 2026-11-20 tinted each event with its calendar's colour and
kept a filter page for hiding calendars, plus a Refresh button. Maxim asked how
to tell where an event comes from, then asked to remove the filter ("why is it
there at all?") and Refresh, to make the main buttons narrower, to add logos to
the Connect list and to put a small logo on each event instead of the colour.
He also asked whether Whytap can learn about changes by itself.

## Decision

- Every event block has the same blue. A small logo of its service leads the
  title: Google Calendar, Outlook, Calendar on this Mac, Zoom or Whytap. The
  calendar's name stays in the block's second line.
- Logos come from the bundle (Google Calendar mark on a white tile, Zoom,
  Whytap) or from the installed app (Calendar, Outlook). Without Outlook a
  calendar symbol on an Outlook-blue tile is drawn. Nothing is downloaded.
- Hover shows every connected calendar. The filter button and the calendar list
  page are removed. The saved hidden-calendar list is kept and ignored: it is
  part of settings backups and older builds still read it.
- The Refresh button is removed. Calendars still refresh on opening, on a day
  change, on an account change and every 60 seconds while visible. Calendar on
  this Mac updates at once through EventKit's change notification. A mini
  spinner shows while an update runs.
- The day switcher is one compact centered row.
- Connect rows show provider logos. Connection errors, the store's Retry and
  the pointer to Settings → Integrations moved there from the removed list.
  Apple shows Connected once enabled; a connected web provider offers Add account.
- Provider calendar colours are no longer read.

## Why

- The user wants to know which service an event belongs to. A logo says that
  directly; a colour has to be learned and was chosen by the provider.
- Hiding calendars was a setting nobody asked for, and it cost a page and a
  button in a 312 pt panel.
- Google, Outlook and Zoom can only push changes to a server with a public
  webhook address, and Whytap has no servers. Polling while the panel is open,
  plus EventKit's notification, already keeps the day current, so a manual
  button added nothing.

## What we tested

- Unit tests: each event's service (Google, Whytap, a vanished calendar), every
  calendar shown even with a hiding choice saved by an older build, deduplicated
  copies from two calendars, connected-state labels, logos from the bundle
  (not template images), Calendar from the installed app, the Outlook tile when
  Outlook is missing, and a missing asset returning no image.
- Offscreen renders at 310, 360 and 500 pt: the day with logos, the Connect list
  with logos and a connected Google account.
- Not verified: the installed app's look, the Outlook app icon (Outlook is not
  installed on the test Mac) and real pointer behavior.

## Rejected

- Keeping colours and adding logos: two signals for one fact.
- Downloading an official Outlook icon: needs the owner's approval; the
  installed app's icon or a drawn tile covers it for now.
- Push notifications from Google or Microsoft: they need a public server.

2026-11-21 · PR: Calendar logos instead of colours
