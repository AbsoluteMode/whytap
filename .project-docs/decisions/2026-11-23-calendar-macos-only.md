---
id: calendar-macos-only-2026-11-23
type: decision
title: Calendar connects only through the calendars of this Mac
summary: Hover and Settings offer one permission for Calendar on this Mac (EventKit); Google, Outlook and other accounts come through Internet Accounts, each calendar has a tick, direct Google/Outlook/Zoom sign-in has no button but its code and existing connections stay.
status: confirmed
tags: [calendar, eventkit, oauth, integrations, hover, settings]
canonical_for: [calendar-macos-only]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-23 the maintainer, through the orchestrating session, reported that in build 1724 Google was blocked by "Google verification is not complete" and Microsoft's sign-in showed Whytap as unverified, that he had added Google and Outlook to the macOS Calendar instead and saw their events through Apple Calendar, and decided to rework Calendar around access to the Mac's calendars. He approved the plan and its list of losses, including Zoom Calendar, and asked that the OAuth code not be deleted.
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarConnections.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsCalendarIntegrationsView.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Planner/CalendarMacOnlyTests.swift
    confirmed_at: 2026-11-23
related: [2026-11-22-calendar-release.md, 2026-11-26-every-feature-in-features.md]
---

# Calendar connects only through the calendars of this Mac

## Context

Calendar offered four connections: Google, Outlook, Apple Calendar and Zoom.
Google's shared sign-in is blocked until Google verifies the app ("Google
verification is not complete"), Zoom's until Zoom publishes it, and Microsoft
shows Whytap as an unverified publisher on its sign-in page. The maintainer
added his Google and Outlook accounts to macOS (System Settings -> Internet
Accounts) and saw their events in Whytap through Apple Calendar.

## Decision

- **One way to connect.** Hover's Connect page becomes **Calendars** and Settings
  -> Integrations -> Calendars becomes one card, **Calendars on this Mac**. Both
  show `CalendarConnections.macAccess`:
  - *not asked*: one **Allow access** button (the macOS prompt, from the user's
    tap only);
  - *refused*: what to turn on in Privacy & Security -> Calendars and **Open
    Privacy Settings** (the access states of the
    [release decision](2026-11-22-calendar-release.md) are unchanged);
  - *no calendars*: add an account in Internet Accounts;
  - *ready*: the calendars grouped by their EventKit source (iCloud, an address,
    Exchange) with the service logo and a tick each.
  **Open Internet Accounts** is on both surfaces.
- **Ticks are back.** Unticked calendars of this Mac leave the day; the choice is
  the saved `planner.calendar.hiddenFeeds`, so it survives restarts, backups and
  sync. Only `apple:` calendars can be unticked; Whytap's own events and direct
  accounts are always shown.
- **Direct sign-in has no button.** The Google, Outlook and Zoom cards, their
  "Awaiting verification/publication" states and the provider rows are gone from
  the interface. `CalendarOAuth`, `CalendarRemoteClient`, the provider branch of
  `CalendarConnectionFlow`, client registration and their tests stay: deleting
  the collaborator's code is a separate decision of the maintainer.
- **Existing direct connections keep working.** They keep refreshing, are listed
  in Settings under **Connected directly** with Disconnect and a note to move the
  account to Internet Accounts, and an expired sign-in now says to do that
  instead of pointing to a Connect button that no longer exists. When the same
  account is also on the Mac, events with the same iCalendar UID show once.

## Why

The direct connections need each provider's approval of Whytap (Google OAuth
verification of a restricted calendar scope, Zoom publication, Microsoft
publisher verification), which Whytap does not have and which ordinary users
experience as a blocked button or a warning screen. macOS already syncs those
accounts, holds their credentials and asks one clear permission; Whytap then
reads them locally without tokens, network requests or a review. It also matches
the product's rule of no Whytap servers.

Keeping existing direct connections working avoids a silent break for anyone who
connected one; offering the move instead of forcing it keeps their data until
they choose. Ticks came back because, with every account of the Mac in one list,
holiday, birthday and shared calendars would otherwise crowd the day (the
2026-11-21 removal of hiding was requested by the collaborator, not the
maintainer).

## What we lose without the direct APIs

- Zoom Calendar Service calendars (Internet Accounts cannot add them); Zoom links
  inside Google and Outlook events still join.
- Structured meeting fields: a link that exists only in Google's
  `conferenceData`/`hangoutLink` or Graph's `onlineMeeting.joinUrl` and not in the
  event text is not found. Google puts the Meet link in the description and
  Teams invitations carry it in the body, so ordinary meetings keep it.
- Opening an event on the provider's web page (Calendar on this Mac opens it).
- Per-account permission: macOS grants all calendars of the Mac at once.
- Update timing: macOS decides (iCloud and Exchange push; Google over CalDAV is
  fetched every few minutes); direct accounts were polled every minute.
- Shared or secondary Google calendars appear only if Google syncs them to the Mac.

## Builder review (queue #465)

The first review found five gaps, all fixed in the same PR: Settings now reads
the calendar list itself (`prepareMacCalendars()` on appear, on app activation
and after Allow, status only for an unconnected Mac); accounts are grouped by
EventKit's source identifier, and repeated names get their service; a saved
connection with access off keeps **Disconnect** next to **Open Privacy
Settings**; inactive hidden-calendar entries of direct connections make room
instead of using up the limit for calendars of this Mac (the saved set stays
within the backup and sync bound); and the recovery text names the button both
surfaces show, **Allow access to calendars**.

The second review (queue #471) found that this list load read today's events
and replaced the events of another day already open in Hover. Settings now asks
EventKit for the calendars alone (`AppleCalendarAccess.list`); events are read
only by the day's refresh, and only the events of a calendar that left the Mac
are dropped.

## What was tested

`CalendarMacOnlyTests`: states from not asked through loading, no calendars and
ready to refused; a refused Allow asking for Allow access again and returning to the
one button once allowed; one tap from the Calendars page connecting and showing
the day; grouping by account with the service and sorted calendars; unticking
calendars, an invitation in two calendars staying while either is ticked,
Whytap's own events never hidden, the choice surviving a restart; Meet, Teams and
Zoom links found in description text; a direct Outlook account still refreshing
and never hidden; the expired-sign-in message; and, after the builder review,
Settings loading the list on relaunch, after Allow and after recovery (never for
an unconnected Mac), same-named accounts kept apart with and without a source
identifier, the card's buttons per state, Disconnect of a revoked connection,
inactive direct entries making room while the limit holds for this Mac, and the
recovery text naming the visible button; after the second review, a day other
than today open in Hover keeping its events while Settings loads the list twice
without an event read, a removed calendar taking its events with it, and an
empty Mac reported as no calendars instead of loading. `CalendarReleaseTests` still
cover the access transitions. `CalendarConnectRenderTests` writes the Hover
Calendars page and the Settings card in all four states (light and dark).
EventKit with the maintainer's real Google and Exchange accounts can only be
checked on his Mac; that is the acceptance.

## Rejected

- **Keep the four providers and wait for approvals.** Users would keep seeing a
  blocked Google row and an unverified Microsoft page.
- **Delete the OAuth code.** The maintainer keeps that decision.
- **Disconnect existing direct accounts.** A silent loss of events.
- **No ticks, show every calendar.** Every account of the Mac in one day is too
  much; hiding was only removed while Calendar listed providers.

2026-11-23, PR: see the pull request that made Calendar on this Mac the only connection.
