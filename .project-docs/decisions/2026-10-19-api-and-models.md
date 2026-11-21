---
id: api-and-models-2026-10-19
type: decision
title: API & Models - provider keys once, one model per AI feature
summary: Settings -> API & Models replaces Models. Keys are entered once per provider; each of eight AI features has its own provider and model, read on every call. Catalogs and synthetic probes decide which models are offered; Whytap never changes a model or provider by itself.
status: confirmed
tags: [settings, models, keys, routing, migration, agent, anthropic, privacy]
canonical_for: [feature-model-routing, api-and-models-tab]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: 2026-10-19 design chat; the compact layout (key chips plus one picker per feature row), the feature list and "new models - variant B" were approved by Maxim.
    confirmed_at: 2026-10-19
  - type: user-confirmed
    reference: 2026-10-19 request from the "credits usage" session; add Anthropic for the Agent row only, so the agent can spend Anthropic API credits.
    confirmed_at: 2026-10-19
  - type: repository
    reference: docs/specs/api-and-models.md
    confirmed_at: 2026-10-19
  - type: repository
    reference: docs/plans/api-and-models.md
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/AIRouting/AIRoutingStore.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/APIAndModelsView.swift
    confirmed_at: 2026-10-19
related: [2026-10-18-remove-local-models.md, 2026-10-19-strict-drop-modes.md, 2026-10-19-deepgram-language-policy.md, 2026-10-19-api-hints.md, 2026-10-21-provider-key-tiles.md, 2026-11-17-openrouter-model-prices.md, 2026-11-19-on-device-dictation.md, 2026-11-19-provider-failure-reasons.md, 2026-11-20-elevenlabs-scribe-v3.md, 2026-11-20-speech-model-lists.md, 2026-11-20-settings-sync.md, 2026-11-21-recorded-meeting-models.md, 2026-11-21-subtitle-speech-translation.md, 2026-11-22-subtitle-audio-translate-slot.md]
---

# API & Models

The chip layout and Anthropic-agent-only restriction below are superseded by
[provider key tiles and direct LLM access](2026-10-21-provider-key-tiles.md).
This record retains the original 2026-10-19 decision and validation history.

## Context

Before this change the speech provider and the text model were global.
`SelfKeyPreferences.selectedProvider` fed Drop, agent voice, voice search,
meetings and the Drop fallback. One LLM (`llmLevel` + `openRouterModel`) served
Drop Smart cleanup and meeting notes. The agent had its own OpenRouter key and
model in the Agents tab, a second place to type the same OpenRouter key.
Real-time models were one hard-coded model per provider, so the Models tab
drew `models.first` while the factory sent the saved model. On Maxim's
production this showed `stt-rt-v5` on screen and sent `stt-rt-v4` (a Soniox
alias that the provider will drop). Nothing checked whether a model could do
tool calls, which the agent needs.

## Decision

- One tab, **Settings -> API & Models**. **API keys** is a row of provider
  chips with a status dot (Soniox, Deepgram, ElevenLabs, OpenRouter, Anthropic
  for the Agent row only, and any number of the user's own OpenAI-compatible
  servers). **Models** has one row per feature and one picker per row, with the
  provider shown in the model's name ("Soniox · stt-rt-v5").
- Eight features, each with its own route (provider account + model) stored in
  `AIRoutingStore`: Drop Fast, Drop Smart, Drop Smart cleanup, Meetings,
  Meeting notes, Agent, Agent voice, Voice search. The runtime reads the route on
  every call. `DropTake` latches the Drop mode and route when a take starts, so
  Retry and recovery follow the take, not the current preference.
- The Drop fallback transcription and agent batch voice go to the provider of the
  feature that led them, with that provider's recorded model from the built-in
  registry. Never to another provider.
- Keys stay in the Keychain accounts they already used
  (`byok.<provider>.api_key`, `byok.openrouter.llm_api_key`,
  `byok.custom_llm.api_key`); new accounts are `byok.anthropic.api_key` and
  `byok.server.<uuid>.api_key`. An unreadable Keychain item fails closed
  (`missingKey`), never a keyless connection.
- Models come from provider catalogs plus a built-in registry of verified
  models. A model outside the registry is usable after a synthetic probe when it
  is picked or on Check now. A failed probe leaves the previous model and shows
  the reason ("Not supported yet"). The row shows a status only when something is
  wrong (Not verified, Deprecated alias, Removed by provider, Not supported yet,
  Key problem, Not set); one common problem on several rows becomes one group
  action ("Switch 4 features to stt-rt-v5").
- The first launch migrates the old choices into routes (`AIRoutingMigration`),
  silently and offline. Old UserDefaults keys are read, never written or
  removed, so a rollback finds the old settings.
- The Agents tab keeps OpenCode install, shortcuts, actions and Save & connect;
  the agent's key and model live in API & Models and Agents shows
  "Model: <provider> · <id>" with Change in API & Models.
- Anthropic is offered for the Agent row only: key in the Keychain
  (`byok.anthropic.api_key`), free key check and catalog from `GET /v1/models`,
  OpenCode's `anthropic` provider with the key passed explicitly in the child
  environment. Drop Smart cleanup and Meeting notes do not offer it.
- Input language is not a per-row setting. It stays global (island and
  Meetings settings); a Deepgram row shows a warning when its model does not fit
  the current language.

## Rationale

- The user spends different money on different things: speech, cleanup, notes,
  agent. A single global provider cannot express "Soniox for dictation,
  Gemini for cleanup, Claude for the agent".
- The screen must show what is sent. Per-feature routes read at call time
  remove the `models.first` versus saved-model gap that hid `stt-rt-v4`.
- No silent changes is the project's rule (invariant 3, remove-local-models):
  an alias is flagged and a switch button is offered; the model is never swapped
  for the user. Removing a key leaves features Not set and moves nothing.
- Data for a feature, its fallback and its probe goes only to the provider the
  user chose for that feature. Probes use synthetic input only, so checking a
  new model cannot leak dictation or notes.
- Catalogs alone cannot say whether a model fits a feature (none of the
  providers publishes enough), so the decision is catalog data, the built-in
  registry and a cheap probe. Routing it through verification lets new
  provider models appear without a Whytap release, while untested ones are
  labelled instead of hidden or silently trusted.
- Reusing the Keychain accounts avoids asking anyone to re-enter keys after
  the update.
- Fast/Smart rules from PR #35 stay with `DropOutputPolicy`; `DropTake` only
  fixes mode and route once at take start, so there is no second copy of the
  rule to drift.
- After an unreadable Keychain item the runtime fails closed, but the migration
  treats it as "key exists" and assigns the route: the migration runs once,
  and a transient denial must not silently drop the user's choice forever.

## Validation

- Full Swift suite: Part A 3062 tests, Part B 3139, final run (with Anthropic
  and these docs) 3154 tests in 58.6 s. All with 0 failures and 5 skipped.
  Network is stubbed (`StubURLProtocol`, `StubWebSocketTransport`); no live
  request with real keys was made.
- Migration: Apple Silicon without a stored level stays Not set even with keys
  in the Keychain; a stored `stt-rt-v4` is kept as is; unreadable key keeps the
  route; two servers (real-time and LLM) become two entries.
- Failure paths: removing a key unsets features and reassigns nothing; offline
  or 5xx on a catalog refresh keeps the cache, marks "Couldn't refresh" and
  removes nothing; a server without a key sends no `Authorization` on any path.
- Deepgram catalog (public `/v1/models`, 19.10): `nova-3` appears as
  `nova-3-general`. The catalog adds the `<arch>` id for `<arch>-general`;
  without it every Deepgram row would have shown "Removed by provider".
- Real OpenCode 1.17.12, dummy key, temporary XDG directories, no model
  request: an empty model object gives `limit.context` 0 (context compaction
  off); a declared model gets the limits from the provider catalog
  (`openrouter/anthropic/claude-sonnet-5.5`: 1000000 / 128000, tools on).
  `anthropic/claude-sonnet-5-5` is listed with declared limits and adaptive
  thinking variants. It is missing from OpenCode's models.dev snapshot, so
  OpenCode shows cost 0 and image input off for it.
- Not verified here: how the tab looks and behaves in the running app (the
  picker "Choose model" for a removed model opens the Other model ID window
  because a SwiftUI `Menu` cannot be opened from code), and live responses of
  providers that need a key. Both are in the PR's acceptance steps.

## Rejected alternatives

- Two pickers per row (provider, then model): heavier than the approved layout;
  the provider is part of the model's name.
- Assigning a new key to empty features automatically: it would turn on a route
  only because a key exists. After a key is saved Whytap only offers "Use
  Soniox for" and the user ticks.
- Replacing `stt-rt-v4` with `stt-rt-v5` quietly: works today (alias), but is
  exactly the screen-versus-sent mismatch. It is flagged "Deprecated alias" with
  a switch button.
- A single shared server entry in the migration: the real-time server
  (`selfHostedBaseURL`) and the LLM server (`customLLMBaseURL`) can be different
  machines, so each becomes its own entry (they merge only when URL and key are the same).
- Probing every model each time the tab opens: costs money and sends requests
  for nothing; probes run only on pick and on Check now.
- A recorded clip of speech for STT probes: the target has no SwiftPM
  resources and macOS voices have unclear licenses; 1 s of silence is enough.
- A language menu in each row: language is global, shown in the island and
  Meetings settings; a per-row copy would drift.
- Anthropic for Drop Smart cleanup and Meeting notes in v1: only the Agent
  was asked for.

## Supersedes

"Settings -> Models" in
[2026-10-19-strict-drop-modes](2026-10-19-strict-drop-modes.md) and
[2026-10-19-deepgram-language-policy](2026-10-19-deepgram-language-policy.md)
now means Settings -> API & Models (configuration errors open the row of the
failing feature). The language menu from the Models settings is gone: input
language is chosen in the island and in the Meetings settings, and a Deepgram
row shows a warning instead. Both older decisions stay as written; their
behavior rules still apply. This record also supersedes the "Models" tab
wording in [2026-10-18-remove-local-models](2026-10-18-remove-local-models.md)
without changing its rule that no route is turned on only because a key exists.

## References

Date: 2026-10-19. PR: https://github.com/AbsoluteMode/exodia/pull/43. Spec: `docs/specs/api-and-models.md`. Plan:
`docs/plans/api-and-models.md`.
