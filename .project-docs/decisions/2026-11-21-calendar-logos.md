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
related: [2026-11-20-calendar-day-view.md, 2026-11-21-calendar-soon.md]
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
- Logos are the services' own full-colour icons, bundled: Google Calendar and
  Outlook (official 96 px PNGs, see Follow-up), Zoom and Whytap. Calendar on
  this Mac uses the installed Calendar app's icon. Transparent margins are
  trimmed so all logos are the same size. The app downloads nothing.
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
  (not template images), Calendar from the installed app, a missing asset
  returning no image, and margin trimming.
- Offscreen renders at 310, 360 and 500 pt: the day with logos, the Connect list
  with logos and a connected Google account.
- The builder's review found that Connect rows reading "Connected" or "Add
  account" were still announced to VoiceOver as "Connect". The row text and its
  VoiceOver name now come from one state (Connecting, Connected, Add account,
  Connect), with tests for each.
- Not verified: real pointer behavior and VoiceOver in the installed app.

## Rejected

- Keeping colours and adding logos: two signals for one fact.
- Drawn tiles (a monochrome Google mark on white, a calendar symbol on Outlook
  blue): the user found them small and poor next to real app icons.
- Push notifications from Google or Microsoft: they need a public server.

## Follow-up: real logos, bigger (2026-11-21)

In the installed 2.2.25 (1667) the user found the icons poor and
asked for the real Outlook, Zoom and Google logos, bigger. With the user's
explicit approval two official icons were added to Resources/UsefulLinkIcons:

- `google-calendar.png` (96 x 96, 907 bytes) from Google's product branding
  assets, `www.gstatic.com/images/branding/product/2x/calendar_2020q4_48dp.png`,
  SHA-256 c2a7600e39f41146589f8ff9111d6f756f94d0af6f83ec98ab6768c985bf7d3b.
- `outlook.png` (96 x 96, 6,335 bytes) from Microsoft's Fabric brand icons,
  `res-1.cdn.office.net/files/fabric-cdn-prod_20230815.002/assets/brand-icons/product/png/outlook_96x1.png`,
  SHA-256 14fbe9ba300e217672e2ce38b34f08a5ea4779b1924f4aeb9833b65893a979ac.

Sizes grew: 28 pt on Connect rows (was 20), 15 pt on tall blocks and all-day
chips (was 12), 13 pt on one-line blocks (was 11). The logos name the service
they belong to and are used only for that.

2026-11-21 · PR: Calendar logos instead of colours
