---
id: whytap-calendar-hover
type: decision
title: Calendar stays inside Hover and opens on today
summary: Show a compact daily agenda, inline details and Connect; reuse provider authorization with Settings Integrations.
status: confirmed
tags: [calendar, hover, integrations, planner, oauth]
canonical_for: [calendar-presentation]
verified_at: 2026-10-22
sources:
  - type: user-confirmed
    reference: On 2026-10-22 the user clarified that Connect must start authorization directly and that the intermediate connection form, account-name field and Advanced app setup must not exist.
    confirmed_at: 2026-10-22
  - type: user-confirmed
    reference: On 2026-10-22 the user requested that calendar provider selection retain Connect and omit the explanatory and technical status information shown in their screenshot.
    confirmed_at: 2026-10-22
  - type: user-confirmed
    reference: On 2026-10-21 the user requested that Calendar stay inside Hover, open on the current day and offer Connect; different calendars can be added there or through Integrations.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarHoverView.swift
    confirmed_at: 2026-10-21
related: [2026-10-21-calendar-integrations.md, 2026-10-20-todo-hover.md, 2026-10-19-planner.md, 2026-11-20-calendar-day-view.md]
---

# Calendar in Hover

The agenda list and inline event details below were replaced on 2026-11-20 by an
hour grid whose events join their meeting or open in their own calendar; see
[the day view decision](2026-11-20-calendar-day-view.md).

This supersedes the standalone Planner window as Calendar's normal entry.
The Calendar tile, tool search, assigned hotkey, Toolbox and `whytap://tool/calendar`
all open the same inline panel. Every new opening selects today, including
a repeated Calendar hotkey. Day navigation stays local to that opening.

The header keeps **Connect** visible. The agenda, full event details, source
visibility and provider selection share the same 350pt Hover surface. No
calendar/detail/connection window is created from these paths. Provider
authorization can open a browser or macOS permission prompt; it is an optional
calendar connection, never registration or sign-in to Whytap.

Provider selection shows each calendar's name and **Connect** as one compact,
clickable row. Introductory copy, status subtitles and disclosure chevrons are
omitted. Clicking Connect starts provider authorization directly, without an
intermediate form. Unavailable-connection reasons/errors stay inline on this
list; public-approval gates are unchanged. While connecting, the row shows a
spinner, additional Connect actions are disabled and Cancel remains available.

Connect reuses CalendarConnectionFlow, its PKCE/state validation, public-approval
gates, Keychain storage and serialized connection lease. Settings → Integrations
offers the same providers. Feed visibility and local tasks/events keep their
existing storage and backup formats. Account-name and Advanced app setup forms
are removed from both Hover and Integrations; the build supplies the native
client and accounts receive distinct provider-based names automatically. Settings retains
permission descriptions, disconnection and Calendar privacy. Source users
configure native clients at build time.

Polling fetches the selected day only, on opening/day/account/refresh changes
and once per minute while visible. Native calendar-change notifications refresh
EventKit feeds. A day boundary follows today unless the user navigated away.
Events remain read-only in Hover; retained local events are displayed alongside
connected sources, including events spanning midnight and all-day events.

The menu survives pointer exit. Outside click/Escape dismisses it, except during
its own provider permission flow so switching to the browser cannot cancel OAuth.
Settings permission flows do not pin Hover. Closing their retained Settings
window cancels the operation; closing an unrelated window does not. CalendarConnectionFlow owns the
operation independently of the view: meeting/agent priority can temporarily hide
Hover without cancelling it. Repeating Calendar while connecting resumes that
source list. Success returns to the agenda, activating Hover only if it is visible;
errors remain available for retry. Explicit Back/Cancel ends the operation.
Explicit Cancel/Back can cancel a connection. The menu reacquires keyboard focus
when the connection finishes. All buttons/rows have full-area hover, press,
focus and disabled states; the fixed hit band includes the whole panel.

A visible Calendar defers restore/update restart. Ordinary read-only backup is
unaffected. Google verification and Zoom publication remain pending; this UI
change neither grants permissions nor marks either provider approved.

There are no runtime calls into PlannerWindowController and no shared window
singleton, so a second calendar surface cannot replace the daily event cache.
The legacy Planner editor types and archive are retained for compatibility/tests;
this change does not delete or migrate tasks, events, accounts or credentials.
