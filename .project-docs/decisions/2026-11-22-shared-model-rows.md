---
id: shared-model-rows-2026-11-22
type: decision
title: Two shared rows, Speech and LLM, set every feature's model in two picks
summary: Models opens with a Speech row and an LLM row that write the per-feature routes of their kind in one pick (Meetings gets the provider's recorded counterpart, a feature the model cannot serve keeps its route and says why); the per-feature list moves under Advanced; the rows are read from the saved routes, so nothing migrates or switches.
status: confirmed
tags: [settings, models, routing, app-control]
canonical_for: [shared-model-rows]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22, after clearing Whytap's data, the maintainer found Drop Smart, Agent voice, Voice search and Translation all showing "Choose a model" and asked, through the orchestrating session, to pick one LLM and one transcription model and apply them to everything, with an "Advanced" place for custom per-feature models, so the whole setup takes two clicks.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/SharedModelChoice.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/Settings/SharedModelRowsTests.swift
    confirmed_at: 2026-11-22
related: []
---

# Two shared rows, Speech and LLM, set every feature's model in two picks

## Context

Settings → API & Models → Models listed one model menu per feature: five
speech features (Drop Fast, Drop Smart, Agent voice, Voice search, Meetings)
and four text features (Drop Smart cleanup, Meeting notes, Agent,
Translation). After a reset every one of them said "Choose a model", and most
users want the same speech model and the same LLM everywhere.

## Decision

- Models opens with two rows, **Speech** and **LLM**, above Subtitles (its
  Audio translate slot stays its own). Below them, **Advanced · a model per
  feature** discloses the former per-feature list, unchanged.
- Picking in a shared row writes the routes of its features
  (`SharedModelKind.features`): the same model where that feature's own picker
  offers it; for Meetings (recorded audio) the provider's recorded counterpart
  (ElevenLabs `scribe_v3_live` → `scribe_v3`, Soniox/Deepgram/On this Mac the
  registry's Meetings model). A feature the choice cannot serve keeps whatever
  it had and the row says so in one line ("Agent: no tool support · kept …",
  "Meetings: … · choose in Advanced"). An LLM is never replaced by another
  model.
- The shared picker is the picker of the least demanding feature of the kind
  (Drop Fast; Drop Smart cleanup), so every model that can serve at least one
  feature is offered. Each feature is then planned against its own picker
  sections (`SharedModelPlanner`), so key status, catalog capabilities, the
  Agent's tool/context needs and a server's speech/LLM split decide coverage
  exactly as they do in Advanced. The planner asks one model at a time
  (`ModelStatusResolver.pickerReach`, the same rules as `sections(for:)`)
  and never builds a picker list; the full list is built only when a picker
  opens. A model the feature's picker rules out (`verdict`) is refused even
  where a server section takes a typed name, so an LLM typed into Speech on a
  server set to Language models reaches no speech feature, as in Advanced; a
  name the server does not list can still be typed.
- One check per pick: targets that need a probe are grouped by route and use;
  a passed tool-calling probe also counts as the plain-text check of the same
  model. A refused check changes no route and its reason appears under the row.
- A shared row is not a stored setting. It is read from the saved routes: the
  model most features follow (more than half of those that have one) is the
  row's model, the others are "N custom" and features without a route are
  "N not set". With no majority the row reads "Mixed · N custom" and Advanced
  starts expanded. Re-picking with custom features asks once: Keep custom
  models (default) / Replace them too / Cancel.
- App control: `get_state` gains a read-only `shared` object (label, mixed,
  route, features, custom, unset per kind). `set_model` stays per feature: a
  harness sets each feature of `shared.<kind>.features`, every write keeping
  its own expected value and check.

## Why

- Two picks instead of nine, without losing per-feature control.
- Deriving the row from routes means no migration and no second source of
  truth: older builds, rollbacks, settings sync, backups and the app-control
  `set_model` all keep writing the same per-feature routes, and the row simply
  reflects them. Existing users see their routes untouched (Invariant 3: no
  silent route change).
- Planning against each feature's own sections reuses every rule the pickers
  already enforce instead of duplicating capability checks.
- A shared write tool in app control would be a second write path with its own
  partial-failure semantics; per-feature writes with expected values are
  already atomic and verifiable.

## What was checked

`SharedModelRowsTests` (scenario tests through the real view model, fake
probe, in-memory keys, cached catalogs):

- every active feature belongs to exactly one kind;
- empty Mac → two picks → all nine routes set, Meetings on `scribe_v3`, one
  probe (tools) for the LLM, none for built-in speech;
- an LLM without tool support leaves the Agent's route and says why;
- an Advanced override survives a later shared pick, and is replaced only
  with Replace them too;
- an older Mac with different models reads Mixed and no route moves;
- Soniox with a stored failed check of its recorded model: Meetings skipped,
  "1 not set" with the reason;
- a self-hosted server: speech everywhere with one live check, text for
  cleanup/notes/translation, the Agent not set;
- a failed check changes nothing and shows the reason;
- build queue 397 found two problems in the first version, both now covered:
  a typed LLM on a Language-models server was probed and saved for speech
  (now refused without a check, like Advanced; an unlisted typed name still
  works), and deriving the rows built full picker sections on the main actor
  (3.7 s with a 2,500-model OpenRouter cache in the builder's debug fixture;
  the view model now initializes in about 20 ms with the same catalog);
- offscreen renders (empty, filled, with an override) differ as expected.

`AppControlControllerTests.test_state_reports_the_shared_rows_without_writing`
covers `get_state.shared`.

## Rejected

- A stored "shared model" preference that features inherit: a second source
  of truth, needs migration, and rollback builds would ignore it.
- Substituting another model for a feature the choice cannot serve (e.g. a
  tool-capable model for the Agent): a silent route choice the user did not
  make.
- Overwriting custom per-feature models without asking.
- A `set_shared_model` app-control write: duplicates `set_model` with weaker
  per-feature guarantees.

## Limits

The PR that adds this file overlaps PR AbsoluteMode/whytap#393 (server model
kinds); with it merged, a server's speech and LLM models land in the matching
shared row automatically, because the planner reads the same sections.

2026-11-22. PR: see the commit that adds this file.
