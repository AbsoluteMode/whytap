---
id: whytap-links
type: decision
title: whytap:// links show a place and are routed by the feature enums
summary: Register the whytap URL scheme; exhaustive switches over HoverTool and SettingsWindowTab map every tile and tab to a place that is shown, never executed.
status: confirmed
tags: [links, url-scheme, settings, hover, toolbox]
canonical_for: [whytap-url-scheme]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user decided that new features must become linkable automatically, so the link router is built from the same enums with exhaustive switches and no separate list.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Settings/WhytapLink.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Resources/Info.plist.template
    confirmed_at: 2026-10-20
related: [2026-10-17-hover-tool-search.md, 2026-10-20-toolbox-mini-apps.md, 2026-10-21-whytap-link-hotkeys.md, 2026-11-20-harness-access.md, 2026-11-26-notifications-in-notify.md]
---

## Context

The public question page on the Whytap website answers questions about the
app and generates `whytap://tool/<HoverTool rawValue>` and
`whytap://settings/<SettingsWindowTab rawValue>` links. The site reads both
enums from `main` every six hours. The app registered no URL scheme, so the
site's "Open in Whytap" buttons stayed disabled. The link format is already
fixed on the site.

## Decision

- `CFBundleURLTypes` registers `whytap`; `AppDelegate` installs a `kAEGetURL`
  handler in `applicationWillFinishLaunching` and queues a cold-start link
  until launch has finished.
- `WhytapLink` maps each `HoverTool` and `SettingsWindowTab` with exhaustive
  switches and no `default`. The enums are the registry; there is no list.
- A link only shows a place. Inline tools open the same `HoverPanelRequest`
  as their tile and feature hotkey. Navigate tools and every tab open Settings
  with `setHighlight`. To-do opens its compact inline panel, matching the
  tile and hotkey. Calendar/Translate/Subtitles open their windows idle. Drop
  Mode, Record and Screenshot select their Toolbox pane, where the action
  remains an explicit button. Quit highlights the Quit row. Case opens
  Settings -> Toolbox without selecting its pane: both Case surfaces request
  Touch ID when they appear, and a link must never prompt for authentication.
- Invariant 7: links only show. `WhytapLinkTests` classifies every
  destination kind and inline panel with exhaustive switches and source-checks
  the handler for action calls. A link that changes something (for example
  assigning a hotkey) needs its own decision with in-app confirmation and an
  allowlist that excludes reading data (keys, Case, meetings, clipboard,
  backups) and network destinations (provider endpoints, notification scripts).
  Tool hotkeys became the first such change:
  [2026-10-21-whytap-link-hotkeys.md](2026-10-21-whytap-link-hotkeys.md).
- A well-formed link with an unknown id or kind (a newer site, an older app)
  only wakes the island. Other schemes, credentials, ports, empty or extra path
  segments and ids outside the ASCII alphanumeric raw-value alphabet (`..`,
  percent-escapes) are rejected silently; the URL is never logged.

## Rationale

Any web page can open a `whytap://` URL, so a link must never start a
recording, a screen capture, a mode change or quit. Showing the existing
surface, with its own explicit button, keeps every action behind a click.
Exhaustive switches make a new tile or tab fail to compile until someone
decides where its link goes, and the same raw values are what the site reads,
so the catalog and the router cannot drift. Older apps receiving newer ids
degrade to showing the island instead of an error.

## Tested

Unit tests parse a link for every `HoverTool.allCases` and
`SettingsWindowTab.allCases` and check it against the tile's registry kind and
`HoverSlotRouter` panel. Rejection cases cover other schemes, empty kind/path,
trailing or extra segments, `..` (literal and percent-encoded), non-ASCII and
punctuation ids, credentials and ports. The Info.plist template is checked for
the scheme. Real LaunchServices delivery is verified only after the integrator
installs the build.

## Rejected

- A separate list of linkable ids: drifts from the enums the site reads.
- Opening the Case panel from a link: a web page could trigger a Touch ID
  prompt that the user approves by reflex.
- Running the tile's effect (`HoverSlotRouter.effect`) for links: starts
  recording, capture or quit from any web page.
- Showing an error for unknown ids: older apps would complain about links to
  newer features.
- `default:` branches in the router: a new tile would silently become unlinkable.
- Flavor-specific schemes: beta and dev bundles also register `whytap`; with the
  one-running-copy lease, a second copy launched by a link offers to activate
  the running one and quits.

2026-10-20 — Source PR: [#108](https://github.com/AbsoluteMode/whytap/pull/108).
