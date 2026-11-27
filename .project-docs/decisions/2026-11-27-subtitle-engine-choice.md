---
id: subtitle-engine-choice-2026-11-27
type: decision
title: Subtitles have an explicit engine choice, Soniox or OpenAI
summary: The Subtitles row in Keys & models → Models expands like the other rows and offers an Engine menu with Soniox stt-rt-v6 and OpenAI gpt-realtime-translate. Without a stored choice the engine stays Soniox when its key exists, otherwise OpenAI. A chosen engine runs only with its own key and never falls back; Start names that key when it is missing.
status: confirmed
tags: [translation, subtitles, soniox, openai, settings, models]
canonical_for: [subtitle-engine-choice]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: On 2026-11-27 the owner, through the orchestrating session (task 106 follow-up), asked to give Subtitles an explicit engine choice between Soniox and OpenAI gpt-realtime-translate so people without a Soniox key, or who prefer OpenAI, can pick; the Subtitles row expands like other rows with the engine picker, the default stays Soniox when its key exists and otherwise OpenAI, and Start names the missing key for the chosen engine. This supersedes the "no engine choice" part of the 2026-11-25 record.
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/Translation/SubtitleAudioTranslate.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/APIAndModelsView.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Tests/SidekeyTests/Translation/SubtitleAudioTranslateTests.swift
    confirmed_at: 2026-11-27
related: [2026-11-25-subtitle-soniox-engine.md, 2026-11-22-subtitle-audio-translate-slot.md, 2026-11-27-agent-harness-cli.md]
---

# Subtitles have an explicit engine choice, Soniox or OpenAI

## Context

Since 2026-11-25 Subtitles picked their engine from the keys alone: Soniox
whenever its key could be read, OpenAI only without it, and no choice in
Keys & models (2026-11-25-subtitle-soniox-engine.md). Someone with both keys
who prefers OpenAI could not use it, and the row did not say which engine
would run until Start. The owner asked for an explicit choice while Models
was being reworked for the Agent harness (task 106).

## Decision

- **Where.** Keys & models → Models → Subtitles expands like the other rows:
  a disclosure chevron, and under a separator an **Engine** menu with
  "Soniox · stt-rt-v6" and "OpenAI · gpt-realtime-translate". An engine whose
  key is missing shows "— no key", and the menu ends with "Add a Soniox key…"
  or "Add an OpenAI key…" for the chosen engine.
- **Storage.** `subtitles.engine` in UserDefaults (`soniox` / `openai`).
  Absent means no choice yet.
- **Default.** Without a stored choice the rule of 2026-11-25 is unchanged:
  Soniox when its key can be read, otherwise OpenAI, otherwise Start names
  both keys.
- **A choice is binding.** `SubtitleAudioTranslate.engine(choice:soniox:openAI:)`
  and `engineAndKey(from:choice:)` run the chosen engine only with its own
  key. A chosen engine without a key does not fall back to the other one:
  Start says "Subtitles on OpenAI need an OpenAI key. Add it in Keys &
  models." (or the Soniox variant), and Features shows "No OpenAI key" /
  "No Soniox key" with an "Add a/an … key" action.
- Costs metering, the adapters and the subtitle pairing are unchanged.

## Why

- The owner asked for it, and it removes a hidden rule: the row now says
  which engine runs.
- Keeping the key-based default means nobody's Subtitles change engine on
  update.
- A silent fallback after an explicit choice would send audio to a provider
  the user did not pick; naming the missing key is honest and fixable.

## What we tested

- `SubtitleAudioTranslateTests`: the chosen engine uses only its own key
  (`testAChosenEngineUsesOnlyItsOwnKey`), the row shows the choice and runs
  only with its key (`testTheRowShowsTheChoiceAndOnlyRunsWithItsKey`), and the
  OpenAI key lookup names OpenAI when it is missing.
- `FeatureCatalogTests` / `SettingsFeaturesTests`: the Subtitles requirement
  names the chosen engine's key.
- Rendered the Models page with Subtitles open in light and dark (test
  render, the app was not launched).
- Not tested live: a Subtitles session with each engine after switching.

## Rejected

- Falling back to the other engine when the chosen one has no key: sends
  audio somewhere the user did not choose.
- Writing a choice on update from the current keys: changes nothing useful
  and would freeze today's default for people who later add a Soniox key.

2026-11-27 · task 106 (PR 2 of the harness series)
