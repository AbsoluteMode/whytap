---
id: remove-tool-probe-2026-11-27
type: decision
title: No tool-use model check; earlier tool-use marks are dropped on load
summary: With the Agent on Claude Code or Codex no text feature needs tool use, so the tool-use model probe (OpenAI Responses and Anthropic fake tool), catalogs' tool-support marks and the LLM-with-tools feature mode are removed. Saved catalogs and checks keep decoding; their old chatWithTools values are dropped on load.
status: confirmed
tags: [models, probe, catalog, agent, harness]
canonical_for: [model-tool-use-check]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: On 2026-11-27 the owner, through the orchestrating session (task 106 follow-up), approved removing the .chatWithTools probe and its dead route as a separate small PR after the built-in agent's removal.
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelProbe.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/AIRouting/AIFeature.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelCheckStore.swift
    confirmed_at: 2026-11-27
related: [2026-11-27-agent-harness-cli.md, 2026-11-22-openai-agent-probe-responses.md]
---

# No tool-use model check; earlier tool-use marks are dropped on load

## Context

The built-in agent needed models that accept tool calls, so picking a model
for it ran a tool-use probe (one fake tool; OpenAI through the Responses API,
2026-11-22-openai-agent-probe-responses.md), catalogs marked tool support,
and the `.agent` and retired meeting-text features had an "LLM with tools"
mode. Since the Agent runs on the user's Claude Code or Codex
(2026-11-27-agent-harness-cli.md), nothing asks for tool use.

## Decision

- `AIFeatureMode.llmWithTools` is gone; the inactive `.agent` route and the
  retired meeting-text feature are plain `.llm`. The `.agent` route stays
  stored for Costs history and rollback.
- `ModelProbe` sends only the plain one-word prompt; the fake tool, the
  Responses API path and the OpenAI adapter version 2 are removed. Every
  adapter is at version 1 again.
- Catalogs no longer mark tool support (`ModelUse.chatWithTools`,
  `CatalogModel.supportsTools`).
- Stored data keeps decoding: the old raw value survives only as
  `ModelUse.retiredChatWithTools`, never produced. `ModelCatalogStore` strips
  it from saved catalogs and `ModelCheckStore` drops saved checks for it on
  load; plain-text checks of the same model stay. A stray probe request for
  it sends nothing.
- The Anthropic registry entry that existed only for tool use is removed, so
  Anthropic's direct text model is still checked when picked, as before.

## Why

- Dead code that sends paid probe requests and shapes model lists for a
  feature that no longer runs.
- Removing the enum value outright would make saved catalogs and checks fail
  to decode and lose every verified model; keeping a retired raw value and
  dropping it on load preserves them.

## What we tested

- `ModelProbeTests`: the Anthropic and OpenAI text probes send no tool; the
  retired use sends no request and no feature asks for it.
- `ModelCheckStoreTests`: a saved tool-use check (written with the old raw
  value) is dropped on reopening, the plain check of the same model stays.
- `ModelCatalogStoreTests`: a saved catalog with the old mark loads without
  it. Catalog fetcher, registry, status resolver, shared rows and onboarding
  tests updated.

## Rejected

- Mapping old tool-use checks onto plain text: a tool refusal would mark a
  working text model failed.
- Deleting the `.agent` route: Costs still shows its earlier spending, and a
  rollback build reads it.

2026-11-27 · task 106 follow-up
