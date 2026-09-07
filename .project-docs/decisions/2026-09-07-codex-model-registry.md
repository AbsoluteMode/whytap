---
id: codex-model-registry-2026-09-07
type: decision
title: Discover Codex models and controls from its app-server registry
summary: Replace the GPT-5.5 pin and fixed reasoning/speed choices with model/list capabilities.
status: confirmed
tags: [codex, agent, models, reasoning, speed, settings]
canonical_for: [codex-agent-model-selection]
verified_at: 2026-09-07
sources:
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/CodexModelCatalogReader.swift
    confirmed_at: 2026-09-07
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/AgentSettingsStore.swift
    confirmed_at: 2026-09-07
  - type: url
    reference: https://learn.chatgpt.com/docs/app-server
    confirmed_at: 2026-09-07
related: [../project.md]
---

# Codex model registry

## Context

Whytap exposed only GPT-5.5 and rewrote every stored Codex model to that ID.
Reasoning levels were fixed at low through xhigh, and speed support was guessed
from a Spark model-name exception. The binary locator also missed the current
CLI bundled in ChatGPT.app and fell back to an older npm installation.

## Decision

Use the located Codex CLI's stdio app-server: initialize, initialized, then
paginated model/list with includeHidden=false. Read model IDs, display names,
supportedReasoningEfforts, defaultReasoningEffort, serviceTiers and defaults.
For older responses, additionalSpeedTiers is a fallback only when serviceTiers
is absent. An explicit empty tier array means no additional speed mode.
Prefer the current ChatGPT.app bundled CLI, then the existing Codex.app and
standalone CLI locations. Discovery uses the same environment scrub as execution.

Discovery runs off the main thread, with an eight-second protocol deadline,
cancellation, bounded response size/pagination, and process cleanup. It does
not create agent threads, send prompts or read credentials. Refresh at startup,
on opening Agents (one-minute successful-refresh cache), and on Refresh models.
A failure preserves the last successful in-memory catalog and offers retry.

Model resolution is saved choice, CLI config, registry default, then the first
registry model. Do not rewrite saved choices. Keep an unavailable saved model
visible so the user can choose a replacement. Without capability information,
let Codex resolve reasoning and speed rather than inventing supported options.

The UI and execution share AgentSettingsStore.options. Resolve an unsupported
stored effort to that model's registry default. Resolve unsupported speed to
Normal. Preserve preferences so switching back restores compatible choices.
Normal explicitly sends service_tier=default, overriding an inherited fast
config. New and resumed turns receive the selected model and validated controls.
Claude model settings remain unchanged.

## Alternatives

A new hardcoded list would become stale again. Reading Codex's cache directly
would bypass the installed CLI's availability filtering; the older CLI and the
current desktop CLI returned different visible model sets during verification.

## Verification

The installed desktop CLI 0.153.1 returned Astra, Sol, Terra, Luna and other
visible models, per-model effort levels including max/ultra, and Fast tier
metadata. The older npm CLI 0.147.0 omitted Astra. Tests exercise protocol
handshake/pagination, hidden/duplicate filtering, timeout/cancellation, older
speed fields, preservation of choices, model-specific controls and CLI flags.

## Consequences

Available choices follow the user's installed and signed-in Codex. A new model
or reasoning level no longer requires a Whytap release. An unavailable catalog
is recoverable through Refresh models; no remote model list is hardcoded.
