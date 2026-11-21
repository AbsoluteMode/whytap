---
id: whytap-calendar-integrations-2026-10-21
type: decision
title: Feature-specific calendar connections and public verification gate
summary: Integrations lists each calendar feature and its permissions, while unapproved shared Google and Zoom registrations cannot start browser sign-in.
status: confirmed
tags: [calendar, integrations, google, outlook, apple, zoom, oauth, verification]
canonical_for: [calendar-integration-entry, public-calendar-approval]
verified_at: 2026-10-24
sources:
  - type: user-confirmed
    reference: 2026-10-24 chat; the public gate also blocks the owner's real verification demo, which must be reachable without restoring the rejected setup form.
    confirmed_at: 2026-10-24
  - type: repository
    reference: Sources/Sidekey/Planner/GoogleCalendarReviewSession.swift
    confirmed_at: 2026-10-24
  - type: user-confirmed
    reference: 2026-10-22 chat; clarified that Connect should directly start provider authorization with no intermediate connection form or app setup.
    confirmed_at: 2026-10-22
  - type: user-confirmed
    reference: 2026-10-21 chat; requested calendar feature connections in Integrations, included Zoom, and rejected the Google unverified-app warning for public use.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsCalendarIntegrationsView.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Planner/CalendarIntegrationFeature.swift
    confirmed_at: 2026-10-21
related: [2026-10-19-planner.md, 2026-10-21-calendar-hover.md, 2026-11-20-calendar-day-view.md, 2026-11-21-calendar-soon.md]
---

## Decision

Settings → Integrations lists Google Calendar, Outlook Calendar, Apple Calendar
and Zoom Calendar separately. Each entry describes the actual calendar access,
shows its connection or approval state, and starts provider authorization directly.
There is no intermediate connection sheet, account-name field or app setup.
The [Calendar in Hover decision](2026-10-21-calendar-hover.md) owns the compact
source list and feed controls. Source users supply native client configuration
when building; ordinary users do not enter OAuth client configuration.

Registration and production publishing status are not evidence of provider
approval. Shared Google and Zoom clients require an explicit packaging approval
flag before new browser sign-in can start, including from Planner. Missing or
malformed approval stays closed. Existing connections and local events remain
available; disconnection remains possible. A source user's independent native
client is separate from Whytap's shared registration.

For the owner's real verification recording, an explicit process-local Google
review session temporarily permits direct Connect with the same registered
client. It requires a finite future deadline no more than two hours ahead and
is disabled on an ordinary launch. It does not change the packaged approval
flag, grant calendar access, select an account or open Zoom. This developer
opt-in is not an account-identity restriction. Expiry blocks new sign-ins;
completed grants remain until disconnected or revoked. The designated builder
owns the safe one-app launch; no setup form or persistent preference is added.
The verification guide documents activation and the read-only runtime boolean.

Only set the public approval flag after the actual provider decision. Fixtures,
branding verification and a published domain do not justify that flag. See
[Google verification preparation](../../docs/google-calendar-verification.md).

The shared connection coordinator serializes Settings and Planner sign-in.
An active connection flow defers Sparkle restart and backup restore, including
when the originating window closes; ordinary backups remain available.
Conversely, backup work, a staged restore or pending maintenance blocks new
connection changes until it finishes, so restored metadata cannot erase a new
account. The retained development-only native-client editor clears a previous client's
desktop secret when its ID changes; normal Hover/Integrations do not open it.

## Why

The user wants to connect a capability with understandable permissions.
Provider-level account login must not suggest access to unrelated email,
recordings or transcripts. A clear pending state inside Whytap avoids sending
public users into the Google warning the user explicitly rejected.

Scoped integration buttons and links respond across their full area to hover,
press and keyboard focus; disabled controls stay visibly unavailable and inert.
This follows the user's interaction feedback requirement without changing
unrelated Settings controls.

## Verification limits

Synthetic tests and offscreen renders cover readiness, blocked browser launch,
connection serialization, restore/restart deferral, long labels, errors and
control states. Real provider approval and live consent are separate external
acceptance. No Google access was granted during the warning-screen check.
