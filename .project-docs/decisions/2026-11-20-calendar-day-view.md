---
id: calendar-day-view-2026-11-20
type: decision
title: Calendar in Hover shows a classic day and a click joins or opens the event
summary: The agenda list became an hour grid with events from start to end in their calendar's colour and name; a click joins the meeting link, else opens the event in its own calendar; the inline details page is gone.
status: confirmed
tags: [calendar, hover, planner, design]
canonical_for: [calendar-day-view]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user asked for a classic calendar day (the whole day with events marked on it, each showing its end time and which calendar it comes from) and for a click on an event to open it in its calendar or join its meeting; an own Whytap calendar was set aside.
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarHoverView.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarDayLayout.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Tests/SidekeyTests/Planner/CalendarDayViewTests.swift
    confirmed_at: 2026-11-20
related: [2026-10-21-calendar-hover.md, 2026-10-21-calendar-integrations.md, 2026-11-21-calendar-logos.md, 2026-11-21-calendar-soon.md]
---

# Calendar day view in Hover

> Calendar colours and the calendar list were replaced on 2026-11-21 by service
> logos with every calendar shown: `2026-11-21-calendar-logos.md`.

## Context

The Hover agenda listed events as rows with only a start time. Maxim looked
at the Calendar and To-do video on 2026-11-20 and found that events lacked
their end ("from - to"). He wanted a classic calendar day instead, where the
whole day is visible with events marked on it, and each event shows which
calendar it comes from. A click should either open the event in its calendar
or join the meeting right away. He also considered an own Whytap calendar,
then set that idea aside for now.

## Decision

- The agenda becomes an hour grid. The whole day scrolls, 44 pt per hour, with
  hour labels on the left. It opens one hour before now on today. On another
  day it opens one hour before the first timed event, or at 8 AM on an empty day.
  On today a red line marks the current time.
- A timed event is a block from its start to its end. The block is tinted with
  its calendar's colour and has a solid 3 pt edge. A tall block shows the title,
  then "11:00 - 12:00 · Work". A short block shows the title and its start time
  on one line. A block is never shorter than 18 pt. Overlapping events share the
  width side by side. Events that cross midnight are cut at the day's edges.
- All-day events sit above the grid as chips in their calendar's colour.
- A calendar's colour is the provider's own: Google and Zoom `backgroundColor`,
  Microsoft `hexColor`, EventKit's calendar colour. If none is reported, the
  colour is a stable choice from the calendar's identifier (FNV-1a). Whytap's
  local events are blue. The calendar list shows the same colour dot.
- A click joins the event's meeting link. Without one it opens the event in its
  own calendar: Google `htmlLink`, Outlook `webLink`, or Calendar on this Mac
  through `ical://ekevent/<calendarItemIdentifier>?method=show&options=more`.
  An event with neither is not a button. The tooltip names the action and gives
  the title, time and calendar.
- The inline details page (notes, location, Join meeting, Open original) is
  removed.

## Why

- A list with start times hides how long things take and where the free time
  is. A grid shows both at a glance, which is the classic calendar day the user
  asked for.
- Colour plus the calendar's name answers "which calendar is this from" without
  opening anything. Using the provider's colour keeps it the same colour the
  user knows from Google, Outlook or Calendar.
- One click to join is the action people take right before a meeting. The
  details page was a stop on the way that the user did not want.
- Positions are hours measured from the start of the day, not clock hours. A
  daylight-saving day is then 23 or 25 hours long and every event still lands
  at its real time.

## What we tested

- Unit tests (`CalendarDayViewTests`) cover:
  - overlap columns, including a column that is reused once its event ends;
  - clipping at midnight and the minimum block height;
  - 23 and 25 hour DST days;
  - the opening hour;
  - join before open, nothing for an event with nowhere to go, and the opened URLs;
  - the Calendar URL with escaped identifiers;
  - colour parsing and the fallback;
  - colours and actions coming from a fake Google calendar list.
- Offscreen renders at 310, 360 and 500 pt show a day from two fake Google
  calendars plus local events: overlapping blocks, an all-day chip, the now
  line, a long Russian title, the coloured calendar list and an empty next day.
- An independent Codex review found five issues; four are fixed with tests or code:
  - VoiceOver now has an explicit activation action on event blocks.
  - Another day re-aims when its first event arrives after the fetch.
  - Rows that start off the hour on a half-hour DST day (Lord Howe) label minutes.
  - "Open in ..." names the service of the link that opens, since a merged
    event can carry another copy's link.
  - The builder's check found that EKCalendar.color can be nil (for example on
    an unsaved calendar), which trapped. Such a calendar now gets the fallback
    colour, and a test covers it.
  - The VoiceOver action is attached only to events that have a link.
  - Not changed: packing reserves 18 pt per short block while drawing 16 pt
    plus a 2 pt gap. That gap is intended.
- Not verified: real pointer hover, the click in the installed app, and whether
  Calendar on this Mac opens the exact event from `ical://ekevent/`. That URL
  is undocumented; if it fails, Calendar opens without the event.

## Rejected

- Fitting the whole day into the panel without scrolling: at about 10 pt per
  hour a 30-minute meeting cannot hold a line of text.
- A month or week view: Hover is 312 pt wide and the user asked for the day.
- Keeping the details page as a second click: the user wants the click to act.
- An own Whytap calendar for creating events: set aside by the user for now.

2026-11-20 · PR: Calendar day view in Hover
