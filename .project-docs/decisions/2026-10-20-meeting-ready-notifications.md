---
id: meeting-ready-notifications-2026-10-20
type: decision
title: Meeting notes notify by default with the Whytap icon
summary: A built-in Notify source announces successful meeting processing and opens that exact note.
status: confirmed
tags: [meetings, notifications, defaults, settings, icon]
canonical_for: [meeting-ready-notifications]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user requested meeting-ready notifications enabled by default for every user, with an off switch and the Whytap icon.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Notifications/MeetingReadyNotifications.swift
    confirmed_at: 2026-10-20
related: [2026-10-19-script-notifications.md, 2026-10-20-notification-cards-and-sounds.md, 2026-11-20-input-language-suggestion.md]
---

# Meeting-ready notifications

## Context

Meeting processing can finish after the user leaves Notes. The user wants a
notification without configuring an external source.

## Alternatives

An agent-configured script requires setup for a built-in event. System banners
introduce a separate permission and presentation flow.

## Decision

Use the existing local Notify queue/history. MeetingReadyNotifications handles
newMeetingAvailable in AppDelegate's existing coordinator event consumer.
Failed processing produces no success notification. No second consumer competes
for the unicast stream.

The built-in Meeting notes source defaults to enabled when its preference is
absent, for existing installations and new users. Explicit off survives relaunch.
Settings → Notifications has the switch and Large / Small selector; Notify →
Sources also has the switch. Small is the initial type. The source uses the
packaged AppIcon.icns in its original colors.

An optional internal meeting UUID is archived with the event. Temporary
notifications and history open that exact note through the existing Settings
Notes selection method. Script payloads cannot supply this internal target;
their link validation stays unchanged. Older histories still decode.

## Rationale

The existing queue provides expiry, hover, accessibility, selected-display
placement, screenshot protection and unread history without an executable
source or system notification permission.

## Sources

The dated user request and implementation path in the frontmatter.

## Comments and objections

The user explicitly requires an off switch. Launch must never reset an explicit
off preference.

## Resolution

Notify on successful completion and preserve the enable and presentation choices.

## Consequences

Stable meeting-based event IDs deduplicate while retained in the bounded
archive. Loading history does not replay old notifications. Clear All and the
500-event limit keep their existing semantics. The built-in source is separate
from the 16 script-source limit and cannot be removed as a script. No meeting
content is added to logs or network requests.

## Supersedes / superseded by

Extends local Notify without changing script configuration or old defaults.

The Small default and type selector are superseded by
[cards and optional sounds](2026-10-20-notification-cards-and-sounds.md).
