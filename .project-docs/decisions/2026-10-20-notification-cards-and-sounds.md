---
id: notification-cards-and-sounds-2026-10-20
type: decision
title: Keep notification cards, remove Small and offer optional sounds
summary: All notifications use cards with unclipped hover enlargement and a persistent optional system sound per source.
status: confirmed
tags: [notifications, settings, sound, hover, compatibility]
canonical_for: [notification-presentation, notification-sounds]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user requested notification sounds, then asked to remove Small entirely and reported that card growth on hover clipped its rounded edge, then explicitly clarified that enlargement must remain.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Notifications/NotificationSounds.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandNotificationPill.swift
    confirmed_at: 2026-10-20
related: [2026-10-20-meeting-ready-notifications.md, 2026-10-19-icon-notifications.md, 2026-11-20-input-language-suggestion.md]
---

# Notification cards and sounds

## Context

The user tried a synthetic Small notification, then requested its removal.
The supplied crop also showed the rounded card edge clipped during hover.

## Alternatives

Retaining the Small selector would keep an unwanted presentation. Disabling
hover growth removes the intended feedback and contradicts the clarified request.

## Decision

Remove Small rendering, stacking and notification-type controls. All events
use the existing left-side card. Ignore legacy presentation fields in source
manifests, payloads and history; a missing title uses the source name. Preserve
IDs, links, meeting targets, history and source enable choices.

Retain 3% hover enlargement, brightness feedback and paused dismissal. Anchor
scale at the top-trailing corner so it grows left/down, preserving the island
gap and keeping the card on screen. Reserve transparent leading/bottom overflow
in the native panel, inset the stroke and extend the hosting click region to
the actual transformed bounds. Reduce Motion keeps the unscaled card.

Offer Off, Glass, Ping and Pop in a labeled sound row per source. Keep sound
off by default and preview an explicit selection. Only fresh accepted arrivals
within the temporary presentation limit can sound. History, duplicates and
suspended delivery stay silent. Bound bursts to one sound per 0.75 seconds;
scripts cannot turn sound on. Sound uses macOS output and volume.

## Rationale

Enough panel space preserves the rounded shape while the pointer target follows the visible enlargement. Local
preferences give the user control of sound without changing script contracts.

## Sources

The dated user request and implementation paths in the frontmatter.

## Comments and objections

No additional product objections were supplied. Default silence and system
sound choices are implementation choices, not additional user requirements.

## Resolution

Use cards throughout; offer optional sound independently for each source.

## Consequences

Former text-free events display their source name. Old presentation fields
are ignored rather than rejected, so existing scripts and archives still load.
No provider requests, notification permission or data migration is required.

## Supersedes / superseded by

Supersedes the Small presentation and selector portions of the linked icon
and meeting-ready decisions. Link validation and meeting defaults still apply.
