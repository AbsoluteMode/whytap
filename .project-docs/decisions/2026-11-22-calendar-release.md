---
id: calendar-release-2026-11-22
type: decision
title: Calendar is released; the Soon switch stays and Apple access refusals point to System Settings
summary: CalendarAvailability.shipped is true, so every Calendar surface works and saved connections come back unchanged; Calendar on this Mac is asked for access only from Connect, and any state short of Full Access tells the user where to allow it.
status: confirmed
tags: [calendar, availability, release, eventkit, permissions, hover, settings]
canonical_for: [calendar-release]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer decided, through the orchestrating session, to release Calendar now that the collaborator's work (day grid and event click, Apple Calendar entitlement, service logos and event details) is in main, and asked that saved connections survive and that the Calendar on this Mac permission flow be checked before release.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarAvailability.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarConnections.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/Planner/CalendarReleaseTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-21-calendar-soon.md, 2026-11-23-calendar-macos-only.md]
---

# Calendar is released

## Context

On 2026-11-21 Calendar was closed as "Soon" behind `CalendarAvailability.shipped`
while a collaborator reworked it ([Calendar is Soon](2026-11-21-calendar-soon.md)).
That work is now in main: the day grid with event click, the Apple Calendar
entitlement for the hardened runtime, real service logos, adaptive event blocks
and hover details. The maintainer decided to release it.

## Decision

- `CalendarAvailability.shipped = true`. Tile, search row, Toolbox pane, the
  tool hotkey, `whytap://tool/calendar` and `whytap://hotkey/calendar`, the
  Integrations card and the event preview work again through the same gates;
  no badge is shown.
- **The switch stays.** Setting it to `false` closes Calendar as "Soon" again
  with every guarantee of the earlier decision; `CalendarSoonTests` now closes it
  explicitly and still checks them.
- **Saved data comes back as it was.** Accounts, Keychain credentials, the Apple
  flag, hidden calendars, backups and settings sync were never touched while
  closed and are read again unchanged; a saved Calendar shortcut registers again.
- **Calendar on this Mac goes through `AppleCalendarAccess`.** macOS is asked only
  from Connect (`requestFullAccessToEvents`). Starting Whytap, opening Calendar
  and the 60-second refresh read only the authorization status, and EventKit is
  not touched at all until the user connects Apple Calendar.
- **Anything short of Full Access is one state, `appleAccessOff`**: refused at the
  prompt, refused earlier (macOS then answers without a prompt), restricted,
  revoked later in System Settings, or "Add Events Only". Settings ->
  Integrations and the Connect page say to turn on Whytap in System Settings ->
  Privacy & Security -> Calendars, with an **Open Privacy Settings** button.
  - *Connect refused:* nothing is saved. The message ends "then press Connect
    again"; after access is allowed, Connect succeeds without a second prompt.
  - *Saved connection, access off later:* Apple events leave the day, the
    connection is kept, its row reads **Access off** (not Connected) and opens
    System Settings. Allowing access is enough: the events come back.
- **Live status, both surfaces.** `checkAppleAccess()` reads only
  `EKEventStore.authorizationStatus` (no prompt, no event read) for a saved
  connection or a refused Connect, never for an untouched calendar. Calendar
  runs it when it opens and Settings -> Integrations when it appears; both run it
  again when Whytap becomes active, i.e. on return from System Settings. A
  refusal message that is no longer true is cleared.

## Why

The switch made the release a one-line change and the gates were already
covering every path, so reopening needs nothing else. Keeping it costs nothing
and lets Calendar be closed again in one edit if a release problem appears.

The only gap found on review was the refusal. macOS shows the calendar prompt
once; after "Don't Allow" `requestFullAccessToEvents` returns false at once, so
the old message "You can connect again when ready" sent the user into a loop of
Connect presses that could never succeed. A revoked access looked the same in
Hover. Naming the System Settings place and opening it is the only way out, so it
is the message. Write-only access is included because Whytap has to read events.

The builder's first review (queue #411) found that the refusal state was only
updated by an event refresh: after the first refusal, allowing access left the
warning in place, a revoked connection still read "Connected" and sent the user
back to the empty day, and Settings showed whatever Calendar saw last. Reading
the status is free and shows nothing, so both surfaces now ask macOS for the
current answer instead of remembering one. A refused Connect deliberately stays
not connected: the user chose "Don't Allow", so Whytap names Connect as the next
step instead of connecting on its own once access appears.

The EventKit calls moved behind a small value of closures so the permission
states can be tested as user scenarios without asking the test machine's macOS
or reading the developer's calendars.

## What was tested

`CalendarReleaseTests` with the real default: Calendar ships open with no badge;
the tile routes to the panel and the panel opens on today; search finds it with
its own description; a saved hotkey registers and appears in Help; links open the
panel and may propose a hotkey; connections saved while closed (Outlook account,
Apple flag, hidden calendar) are read unchanged without a new prompt; nothing
reads EventKit before Connect; access granted; refused (a second Connect gives no second prompt; reopening
keeps the advice); allowed after a refusal (reopening clears the stale warning,
Connect needs no prompt, events appear); "Add Events Only"; revoked (row reads
Access off and opens System Settings without leaving the Connect page) and
allowed again; Settings opened alone reading the live status, updating when
Whytap becomes active and never checking an unconnected calendar; Disconnect
clearing the warning; no calendars and no
connection showing an empty day without an error; an event with a Zoom link joins
the call and one without opens in Calendar, with the service logo of the synced
account. `CalendarSoonTests` now closes the switch and checks that a closed
Calendar never reads the access status, asks or reads events (a failing fake),
and that reopening reads the saved accounts and Calendar on this Mac again.
The live macOS prompt and the hardened-runtime entitlement can only be checked in
the installed signed build; they are the acceptance steps.

## Rejected

- **Remove the switch and the Soon code.** It would be a larger change to every
  surface for no user benefit, and closing again would mean restoring it.
- **Call `requestFullAccessToEvents` on every Connect and keep the old message.**
  After one refusal macOS never shows the prompt again.
- **Request access when Calendar opens or Whytap starts.** A sudden system window
  without a user action; the earlier decisions only ask from Connect.
- **Drop the Apple connection when access is revoked.** The user would have to
  find Connect again after allowing access; keeping it recovers on its own.

2026-11-22, PR: see the pull request that set `CalendarAvailability.shipped` to true.
