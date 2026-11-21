---
id: calendar-event-details-2026-11-21
type: decision
title: Events show their real service, fit their details to their height and preview everything on hover
summary: Calendars synced through Calendar on this Mac show the Google or Outlook logo of their account; day-grid blocks show title, time, description and attendees as their height allows; a History-style bubble shows every detail of a block that cuts something; attendees are read from EventKit and Microsoft Graph and kept in memory only.
status: confirmed
tags: [calendar, hover, planner, design, privacy]
canonical_for: [calendar-event-details]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user asked that a Google calendar synced through macOS show the Google logo instead of the Calendar app icon, that event blocks show the topic, time, description and attendees by priority as their duration allows, and that hovering an event that cannot show everything open a preview with all details like History; Google direct access must stay unchanged during Google verification.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarEventDetails.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarEventPreview.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarHoverView.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Planner/CalendarEventDetailsTests.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Tests/SidekeyTests/Planner/CalendarEventPreviewTests.swift
    confirmed_at: 2026-11-21
related: [2026-11-21-calendar-soon.md, 2026-11-21-calendar-logos.md, 2026-11-20-calendar-day-view.md, 2026-10-21-calendar-integrations.md, 2026-11-03-todo-tree.md]
---

# Calendar event details

## Context

Google, Exchange and iCloud accounts added in macOS Internet Accounts reach
Whytap through EventKit, so every such event showed the Calendar app's icon.
Blocks showed only the title, time and calendar name, and the plain tooltip was
the only way to read more.

## Decision

- **Logo of the real service.** A calendar from Calendar on this Mac keeps the
  `apple` provider (permissions and disconnect depend on it) and gains a
  `displayService` used only for its logo. EventKit exposes the account's type
  and title, not its server, so: an Exchange account is Outlook; a CalDAV
  account whose title is a `gmail`/`googlemail` address or contains the word
  "Google" is Google; a CalDAV account whose title is an `outlook`, `hotmail`,
  `live`, `msn` or `windowslive` address or names Outlook, Exchange, Office 365,
  Microsoft or Hotmail is Outlook. iCloud, On My Mac, subscriptions, birthdays
  and anything else keep the Calendar icon. A Google Workspace account whose
  description is a company address is not recognised and keeps the Calendar
  icon; renaming the account in Internet Accounts to include "Google" fixes it.
- **Blocks fit their height.** On the 44 pt/hour grid a block shorter than a
  title line plus a time line (about 45 minutes) keeps logo, title and start
  time on one line. Taller blocks add, in order: the title's second line, up to
  three description lines, one attendee line ("Anna, Boris +3", without you),
  then more description lines. Line heights come from the fonts, so a
  45-minute block shows title and time, an hour adds a description line.
  Descriptions are shown as plain text; Google's HTML tags are removed.
- **Preview like History and To-do.** When a block cuts or leaves out anything
  (title, time line, description, attendees, location), hovering it shows a
  non-interactive bubble left of the drawer with title, date and time (or All
  day), calendar and account with the service logo, location, the click action
  and meeting link (without its query, which can hold a passcode), the
  description (as much as the island area allows, see Follow-up) and attendees
  (twelve by name, six beside a description, with organizer, you and their
  response; the rest counted). All-day chips preview when their line is
  cut or the event has a description, location or attendees. A block that
  shows everything has no bubble. The block keeps its native tooltip only when
  there is no bubble; with a bubble the tooltip names just the click action.
- **No flicker, no stolen clicks.** The bubble does not take pointer events.
  Leaving an event hides it after 120 ms unless another event is entered, so
  moving across adjacent events switches the bubble without an empty frame.
  The bubble starts beside the block's visible part and is lifted to stay
  inside the island area.
- **Attendees in memory only.** `PlannerEvent.attendees` (name, address,
  organizer, you, response) is filled from EventKit (`EKEvent.organizer` and
  `attendees`) and from Microsoft Graph's `organizer` and `attendees`, which the
  existing calendar view request already returns (no `$select` was ever sent,
  so no request changed). It is left out of `PlannerEvent`'s `CodingKeys`: the
  Planner archive, backups and the helper never contain it, and older archives
  decode unchanged. Nothing logs it or sends it anywhere.
- **Closed while Calendar is Soon.** Everything here sits behind
  `CalendarAvailability.isOpen` (2026-11-21-calendar-soon.md): attendees and
  display services are read only inside the gated refresh, the Hover model
  does not open, and `CalendarEventPreviewState.show` and the island overlay
  refuse the bubble while Calendar is closed.
- **Google direct access is unchanged.** Its scopes and requests are as
  declared for Google verification, and its responses' attendees are not read.

## Follow-up: readable descriptions in the bubble (2026-11-21)

In the Beta the user hovered a Microsoft Teams meeting. The description began
and ended with lines of underscores, shown as thick rules, and stopped with
"…" after a few lines; the bubble looked cut off. Changes:

- Descriptions, in blocks and the bubble, drop decorative separator lines:
  any line made only of `_ - = ─ ━ * ~ :` (and spaces), at least three marks,
  which covers Teams' underscores and Google Meet's `-::~:~::-`. Blank lines
  left behind collapse and are trimmed. Outlook's `text<https://…>` link
  targets are dropped too; the meeting link is shown above.
- The ten-line description limit is gone. The bubble may be as tall as the
  island area (the window ends there, so anything taller was cut off). The
  description is laid out last: it shows whole when it fits, else as many
  lines as remain with "…" on the last one. Beside a description the bubble
  lists six attendees by name instead of twelve.
- The bubble cannot scroll. It lies outside the panel's mouse area, where the
  window passes clicks and the scroll wheel to the app behind it, and leaving
  the event hides it. A scrollable bubble would need the panel's hit area and
  hover tracking to include it; not done without a product decision.
- Offscreen renders at the island's real geometry (300 pt left zone, 400 pt
  area) showed the bubble 280 pt wide, opaque, inside the area, with long
  URLs wrapping and a short event's bubble hugging its content.

## Why

- The logo should name the service the user knows, not the bridge it arrived
  through; the connection stays EventKit, so nothing about permissions changes.
- Priority by height keeps short blocks readable and uses the room tall blocks
  already have.
- The bubble follows the To-do rule the user already accepted: a preview only
  where the row hides something.
- The History bubble zone sits outside the panel's hit area, so a clickable
  bubble would need new window hit-testing; the click on the event already
  joins or opens it.

## Privacy follow-up (required before release)

The public Calendar Privacy Notice (whytap.ai/calendar-privacy) lists the
event fields Whytap reads and does not mention attendees. It must be updated to
cover attendee names, addresses and responses from Calendar on this Mac and
Microsoft before a release containing this change. This change does not edit
the website.

## What we tested

- Unit tests: the service classifier for Google, Outlook/Exchange, iCloud,
  local, subscribed and unrecognised accounts; a feed's logo with and without a
  display service; attendee merging, names, EventKit and Graph responses, the
  compact summary; Graph attendees parsed and Google's ignored; attendees never
  encoded and old archives decoding; merged copies keeping attendees; block
  plans for 15 minutes to 4 hours, title priority, spare room, cut lines,
  location and attendees opening the preview, all-day chips; preview content;
  HTML descriptions; Teams and Google invitation separators and bracketed
  links; description line limits; bubble placement; no empty frame between
  events.
- Not verified: pointer behaviour, the bubble's look and VoiceOver in the
  installed app; real Google/Exchange account titles on other Macs.
