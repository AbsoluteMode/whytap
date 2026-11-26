---
id: lil-bro-removed-2026-11-26
type: decision
title: Lil Bro is removed; Whytap again talks to no Whytap server
summary: The Settings guide Lil Bro and its whytap.ai endpoint are removed from the app. To be really useful he needed the person's questions, the Mac's state, their recent actions and screenshots sent to whytap.ai and kept to improve answers, which zero data retention rules out; without them he was not useful enough to keep. The "no Whytap servers" invariant has no exception again.
status: confirmed
tags: [settings, lil-bro, privacy, network, invariant, ask, removal]
canonical_for: [lil-bro-removal]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26, shown the plan to log Lil Bro's questions so failures could be added to the eval set, the maintainer answered that zero data retention actually rules this out, and then decided to remove Lil Bro ("let's just remove Lil Bro"), relayed by the orchestrator as task 107 REV 30.
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsWindowView.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: docs/privacy.md
    confirmed_at: 2026-11-26
related: [2026-11-24-lil-bro.md, 2026-11-24-lil-bro-answers-from-whytap.md]
---

# Lil Bro is removed

## Context

Lil Bro was a pixel guide over the Settings window (2026-11-24): a person
asked him a question, whytap.ai answered with Claude Sonnet 5.5 and he could
walk to the setting and open it. He was the one exception to "no Whytap
servers". During task 107 the work turned to what would make him really
useful: an eval of real questions showed that people ask vague things ("why
doesn't it work") that only the Mac's state, the person's recent actions in
Whytap and a screenshot can answer, and that failures should be logged on
the server so they can be added to the eval.

## Decision

Remove Lil Bro from the app entirely: the guide and his balloon, the sidebar
entry, the controller, the whytap.ai client, the settings row catalog, the
sprites and their embedding script, the tests, and every mention in the
architecture, privacy and guidance documents. Settings navigation for
links, What's new and the Toolbox stays as it was. The whytap.ai endpoint
`/api/ask/lilbro` is removed in AbsoluteMode/whytap-landing in its own pull
request; the site's own Ask is unchanged. Questions already kept on the
server are handled separately, on the maintainer's word.

## Why

- Zero data retention: being useful required sending and keeping the
  person's questions, the state of their Mac, their recent actions and
  screenshots. The maintainer does not want Whytap to keep that.
- Without that data the guide could not find the cause of a vague
  question, so he was not useful enough to justify a Whytap server.
- Removing him restores the invariant that the app contacts no Whytap
  backend, with no exception to explain in the privacy document.

## What was tested

- Removal: `swift build` and the full `swift test` with no Lil Bro type,
  resource or test left; no source names `lilbro`, `LilBro` or
  `whytap.ai/api/ask`.
- Before removal, an eval of 151 questions (2026-11-26) showed Sonnet
  answered well where the place could be named, but vague questions needed
  the data described above.

## Rejected

- Keeping Lil Bro without a server log: failures could not be collected and
  vague questions stayed unanswerable.
- Keeping him with the state, actions and screenshots sent but not kept:
  still the person's data on a Whytap server; the maintainer chose removal.
- An on-device guide: no on-device LLM is shipped, and a keyword guide was
  already rejected (REV 10).

2026-11-26 · branch feature/remove-lil-bro
