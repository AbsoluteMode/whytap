---
id: server-explicit-models-2026-11-22
type: decision
title: A user's server offers only the models the user added, each with its type
summary: A self-hosted server's form asks for each model's name and its type, LLM or Transcription, and checks it with one small request before adding it; pickers, the shared rows included, show a server model only for its own type. /v1/models only suggests names. Servers from the earlier name-sorting build keep their routes as added models.
status: confirmed
tags: [settings, models, server, self-hosted, ollama, routing]
canonical_for: [server-model-kinds, server-explicit-models]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22, after the name-sorting change shipped in build 1704, the maintainer asked through the orchestrating session (ORCH-TASK 66 follow-up) to make the self-hosted connection explicit, asking for the model name and its type right away, because a name says little ("qwen can be a transcription model too"; the same model is `ut-llm` on one server and something else elsewhere). Each model is checked when added, errors are shown at once, saving without a check is allowed with a mark, "Offer models for" goes away.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/AIRouting/ServerModels.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelStatusResolver.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/ProviderKeyTiles.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/AIRouting/ServerExplicitModelsTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-server-model-kinds.md, 2026-10-19-api-and-models.md, 2026-11-22-shared-model-rows.md]
---

# A user's server offers only the models the user added, each with its type

## Context

The [name-sorting change](2026-11-22-server-model-kinds.md) sorted a server's
`/v1/models` IDs into speech and language models by name, with a per-server
"Offer models for" override. Names turned out to be a weak signal: a company
server calls its model `ut-llm`, another calls the same weights something
else, and `qwen` can be a language model (`qwen3:0.6b`) or a transcription
model (`qwen3-asr`). A per-server override cannot serve a server that runs
both kinds. The user knows what each model is; the app does not.

## Decision

- **Form.** The server form under API keys has Server name (was Name), Base
  URL and the optional key as before, and a Models list. Adding a model takes
  a name (typed, or chosen from "From server", the server's `/v1/models`
  when it has one) and a required type, LLM or Transcription. The name only
  preselects the type (`ServerModelClassifier.suggestedKind`) until the user
  picks one. A new server opens its own form after Save so models can be
  added right away. Rows show the name, the type and, when saved without a
  check, an orange Not checked; × removes the model.
- **Check on add.** `ServerModelChecker` sends one request to the server,
  with the server's own key: an LLM gets a one-line `/chat/completions`
  request (`max_tokens` 16), a transcription model 0.5 s of silence as a WAV
  to `/audio/transcriptions`. A reply with `choices`, or with a `text` field
  (silence transcribes to empty text), passes. Otherwise the form shows what
  the server said and where: "Server answered 404 on /audio/transcriptions —
  this model can't transcribe here (…)", "Server refused the key (HTTP 401)",
  "Couldn't reach the server". After any failed check "Save without check"
  adds it anyway with `checked: false`, shown as Not checked: a server may be
  down while it is set up, and some servers serve a model only on the
  realtime socket.
- **Pickers.** A server section lists only its added models of the kind the
  feature needs (`ServerModel.Kind(feature)`: Drop, Agent voice, Voice search
  and Meetings need Transcription; cleanup, notes and translation need LLM;
  the Agent has no server route). The catalog is not listed and no typed
  name is accepted. A section with no model of that kind is not shown. The
  shared Speech and LLM rows plan through the same picker reach, so they
  offer a server model only for its own kind; a pick for a kind the model is
  not added as is refused with "Not added to <server> as a Transcription
  model".
- **The same name twice.** A model can be added once as LLM and once as
  Transcription (an omni model that does both). They are two entries:
  each was checked on its own endpoint, each shows in its own pickers, and
  removing one un-sets only the routes of that kind. The same name with the
  same type is refused as a duplicate.
- **Saved routes.** The model a feature already runs on stays listed and
  working even if it is not added (for example after it was removed), so
  nothing the user set up stops. Removing a model un-sets the routes of that
  kind on it, and their rows say "<model> was removed from <server>" until
  another model is chosen; nothing moves to another provider.
- **Migration.** Servers carry `models`; a server without the field was
  written by an earlier build. Launch (`AIRoutingMigration`, and
  `reloadFromDefaults` after a restore or sync) turns each such server's
  active routes into added models, with the type of the feature using them
  and marked checked (they were working), and gives a server without routes
  an empty list. The 2026-11-22 `modelKinds` value is ignored and no longer
  written. Routes are not changed. It runs once per server: an emptied list
  stays empty.
- **Storage.** `models` is part of the server's record in the routing
  document (`sidekey.aiRouting.v1`), so backup and settings sync carry it as
  one item, as before. An entry this build cannot read is skipped instead of
  dropping the server (backup validation decodes every server strictly). An
  older build ignores the field.

## Why

The type decides which endpoint the model is sent to, and a wrong guess sends
the user's audio or text to an endpoint that cannot serve it. Asking once,
when the model is added, costs one choice and removes the guess. The check
turns a later failed dictation ("couldn't deliver") into an immediate,
specific message in the form, where the user can still fix the name or
type. Allowing an unchecked save keeps setup possible while the server is
off, and the Not checked mark keeps that visible.

## What we tested

- Scenario tests (`ServerExplicitModelsTests`): `ut-llm` as an LLM appears
  only in text pickers; `qwen3-asr` as Transcription only in speech pickers
  and is picked through the usual probe; one name as both kinds, removal of
  one kind; empty and duplicate names; failed and unreachable checks save
  only through Save without check; a server without `/v1/models`;
  migration of a `modelKinds: both` document (routes unchanged, entries
  derived, idempotent); restore/sync reload; a route on an unadded model.
- `ServerModelCheckerTests` with a stub URL protocol: the exact 404 message
  on `/audio/transcriptions`, the request URL and multipart body, chat and
  empty-transcript passes, key refusal, server error text with the key cut
  out, timeouts.
- A live check against Ollama on this Mac (temporary test, not committed):
  `qwen3:0.6b` as an LLM passes; as Transcription it fails with "Server
  answered 400 on /audio/transcriptions — this model can't transcribe here
  ("qwen3:0.6b" does not support audio input)"; `ut-llm`, which this Ollama
  does not have, fails with "Server answered 404 on /chat/completions — this
  model can't chat here (model 'ut-llm' not found)".
- Offscreen renders of the form (new server, empty list, models with Not
  checked, a refused check) in light and dark at 600 and 900 pt.

## Rejected

- Keep sorting by name with an override: a server can run both kinds, and
  names are arbitrary.
- One type per server: the same server often runs an LLM and Whisper.
- List `/v1/models` in pickers alongside added models: it brings back
  embeddings and wrong-kind models; it stays a source of suggestions.
- Block saving when the check fails: a server being set up may be off, and
  some servers answer only on the realtime socket.
- Probe a transcription model over the realtime socket: the batch endpoint is
  what recovery and Retry use and is one plain request.

2026-11-22, branch `claude/server-explicit-models`.
