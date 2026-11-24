---
id: settings-around-features-2026-11-24
type: decision
title: Settings is rebuilt around features; the feature catalog is data with honest statuses
summary: Settings moves from tabs that follow the code (API & Models, Hotkeys, Permissions, Other) to a list of features and one screen per feature. The first step is FeatureCatalog, the list of features as data, each with its name, one phrase, clip, shortcuts, requirements with a readiness check and one action, and a status in words (Ready, Off, Needs setup, Not set up) that never claims more than the app can check.
status: confirmed
tags: [settings, features, onboarding, status, hotkeys, permissions, models]
canonical_for: [settings-feature-catalog, feature-status-words]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24, after the first outside tester of 2.2.27 could not find his way in Settings, the maintainer decided to make features central, "so that people find it as simple as possible to live and find their way in our settings" (translated), with what a feature does and how to connect it on one screen, and asked that a feature's hotkey and its Hold or Toggle be changed on that feature's screen. He accepted the second clickable mockup with "Yes, I like everything about the settings" (translated). ORCH-TASK 97 REV 16, ORCH-TASK 99.
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Settings/Features/FeatureCatalog.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/Settings/FeatureCatalogTests.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Settings/Features/SettingsFeaturesView.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/Settings/SettingsFeaturesTests.swift
    confirmed_at: 2026-11-24
related: [2026-11-20-other-feature-videos.md, 2026-11-23-keyboard-control-protection-override.md]
---

## Context

The first outside tester of 2.2.27 opened Settings and closed it: one feature
was spread over four or five tabs, the switches of features lived in a tab
named Other, the first screen showed orange outlines without words on models
of features he did not use, and short names (Agent voice, Voice search,
Translation) said nothing about what they were for. His request: say what a
feature does, show how it works and let him set it up in the same place.

A council of three models read the code and proposed a structure; a clickable
mockup was made, reviewed against the code and corrected. The maintainer
accepted the second version.

## Decision

- Settings gets a Features list and one screen per feature: what it does, its
  clip, its shortcut, what it needs with the action in place, its options.
  The work goes in steps; older tabs stay and work beside the new screens
  until each of their settings has moved.
- The list of features is data: `FeatureCatalog` holds, for each `AppFeature`,
  the name, a plain word for what it is, one phrase, the bundled clip if one
  exists, its shortcuts (`FeatureHotkey`, keys read live from
  `HotkeyConfiguration`), how it is turned on, where its settings are shown
  today, and its requirements.
- A requirement is a model route, a macOS permission, the OpenAI key of
  Subtitles, or Drop's shortcut being delivered. Each has a readiness check
  over `FeatureSetupSnapshot` (plain values, no stores) and at most one action.
- Status is words, not colour:
  - **Ready**: every required step is done. A note narrows it ("typing only"
    for search without a voice model).
  - **Off**: the feature has a switch and it is off. Nothing is asked.
  - **Needs setup**: the feature is on and a required step is missing; the
    list names the first one and how many more.
  - **Not set up**: an island tool (Translate & Subtitles, Screenshots) that
    lacks something. It is quiet, like Off: these have no switch, and a tool
    the person never used is not a problem to report.
- A switch exists in the catalog only where the app has one: Agent, Meeting
  Notes, Google search. Drop always waits for its shortcut.
- The free way comes first: where this Mac can run the on-device speech model
  and the feature can use it, the action of a missing speech model is the
  download (or "Use the model on this Mac" once it is there). On an Intel Mac
  the action is a model of a keyed provider, or a key.
- No catalog text names a key (`testNoCatalogTextNamesAKey`), following the
  2026-11-20 rule. Drop's lead paragraph follows the gesture: Hold or press.

- Settings opens on Features, the first sidebar row
  (`SettingsWindowTab.features`, `whytap://settings/features`). The older
  tabs keep their identifiers and their place under it. A row of the list
  opens the feature's own screen or, until it has one, the place its settings
  are shown today (`FeaturePlace`): the Other tab with the Agent group marked,
  or the tool's Toolbox pane. The island's Settings tile opens Features too.
- The list shows no reason under Off and Not set up; VoiceOver still reads it.

## Why

- A newcomer thinks in features, not in providers, routes and permissions.
  The same data drives the list, the screens and later the assistant, so one
  place decides what "ready" means.
- An orange outline on a feature the person does not use reads as an error he
  cannot explain. A missing step is reported only for something that is on.
- "Ready" that ignores the shortcut would send a person away with dictation
  that does nothing. Drop's status therefore includes whether macOS delivers
  its shortcut (`DropHotkeyStatus`): Input Monitoring, a key taken by another
  app, a stale Accessibility entry after an update.
- A status the app cannot check is not drawn as checked: macOS gives no way
  to ask about system audio in advance, so it reads "macOS asks at the first
  recording" and never counts as done or missing.

## Where the mockup and the app differ

The app's behaviour wins, with "simple for a newcomer" as the tie-breaker.

- Drop Fast and Drop Smart keep separate speech routes. In Smart the list
  shows Smart's speech model and text model as required and Fast's model as
  optional; the mockup drew one speech model.
- Input Monitoring is not a separate permission row. Before macOS 27.3 Drop
  works without it and it is asked only when the event tap is refused; on
  27.3 it is part of Keyboard control. The row "Your shortcut is heard"
  covers both, and a shortcut that merely waits for Keyboard control or the
  Microphone is not counted a second time.
- "On this Mac" needs Apple Silicon: an Intel Mac is never offered the
  download.
- Translate & Subtitles and Screenshots have no switch and no Off.
- Google search with no voice model is Ready, "typing only".
- The Agent's web search follows its model and is not a requirement.

## What we tested

`FeatureCatalogTests`: a fresh install without keys (only Drop needs setup,
the first action is the free model); a downloaded model not yet chosen; a
running and a failed download; Intel; permissions missing, a grant that needs
a restart, Input Monitoring, a shortcut in use, a stale Accessibility entry;
Smart mode; a set model whose key stopped working; features that are off;
Meeting Notes and the Agent turned on without models; island tools; a rebound
key and a stale Toggle stored for Space; the summary line; no text naming a
key.

`SettingsFeaturesTests`: the list on a fresh install, an Intel Mac and a usual
Mac read from the live view models; the tab order and identifiers; the
`whytap://settings/features` link; where each row leads; the sidebar fitting
the smallest window; offscreen pictures of the start screen in both themes at
960 x 560 and 1280 x 760.

## Rejected

- Features directly in the sidebar (three groups): six features were named
  twice with different names and statuses, and the rows had to shrink.
- Keeping the orange outline and glow as the "not connected" cue: it carries
  no words and lit up for unused features.
- A switch and Off for island tools: the app has no such switch.
- An Input Monitoring row shown as a permission to allow on every macOS: on
  older systems it would ask for something Drop does not need.

2026-11-24 · ORCH-TASK 99 · feature catalog PR
