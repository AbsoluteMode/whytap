---
id: help-center-link-2026-11-26
type: decision
title: Help Center link next to the website link
summary: The app keeps its whytap.ai link and adds a separate Help item (Settings footer, Help window, island tool search) that opens the Help Center at whytap.ai/help/ in the browser. One constant, no Whytap server contact.
status: confirmed
tags: [help, settings, island, links, privacy, invariant]
canonical_for: [help-center-link]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the owner asked to keep the whytap.ai link in the app and add a separate Help item that sends users to the new Help Center, relayed by the orchestrator as task 71.
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/BuildConfig.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsProjectFooter.swift
    confirmed_at: 2026-11-26
related: [2026-11-26-lil-bro-removed.md]
---

# Help Center link next to the website link

## Context

The owner wanted the whytap.ai link kept and a separate Help item added, so a
user can quickly ask a question on the new Help Center (the Ask Q&A page).

## Decision

- One constant: `BuildConfig.helpCenterURL` = `https://whytap.ai/help/`; the
  website is `BuildConfig.websiteURL`.
- Settings sidebar footer: Whytap (kept), Help (`questionmark.circle`), GitHub.
- Help window: an "Ask a question" button under "Open Learning Center & FAQ".
- Island hover tool Help (`questionmark.circle`), found by tool search ("help",
  "ask question"). Not pinned for existing users and not a tile of the
  onboarding ring (its last step already points to Ask).
- `whytap://tool/help` only shows the Toolbox pane; the page opens from the
  pane's "Open Help Center" button, never from the link.

## Why

The link only opens the browser, so it is the same class as the existing
whytap.ai links and the Calendar privacy page: Whytap itself sends nothing.
There is no status bar menu (invariant 4), so the footer, the Help window and
the island search are the conventional places.

## What was tested

Unit tests cover the URL constant, the router effect, tool search, the symbol
and that existing layouts are unchanged. The full suite had nine stale-count
failures (one more footer link, one more tool); they were fixed and the
affected suites re-run. At first writing `https://whytap.ai/help/` returned
404, so the PR stayed a draft until the new landing was live and returned 200.

## Rejected

- A status bar or menu item: forbidden by invariant 4.
- Replacing the whytap.ai link: the owner asked to keep it.

2026-11-26, PR AbsoluteMode/whytap#511.
