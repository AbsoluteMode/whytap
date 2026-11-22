---
id: openai-agent-probe-responses-2026-11-22
type: decision
title: The OpenAI Agent model check uses the Responses API, like the Agent
summary: Picking an OpenAI model for the Agent (directly or through the shared LLM row) checks it with one function tool on /v1/responses, the endpoint the Agent runs on, instead of /v1/chat/completions, which newer reasoning models such as gpt-6.2-sol refuse with function tools; OpenAI's internal citation marks are removed from Agent answers, and the Search row names the Agent model it follows.
status: confirmed
tags: [agent, native-agent, openai, model-probe, api-and-models, web-search]
canonical_for: [openai-agent-model-check]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer reported, with a screenshot of build 1720, the LLM row error "Agent - Provider refused - Function tools with reasoning_effort are not supported for gpt-6.2-sol in /v1/chat/completions" and the Search row showing Anthropic while the LLM row showed OpenAI (orchestrator task 78, REV 2).
    confirmed_at: 2026-11-22
  - type: url
    reference: https://developers.openai.com/api/docs/guides/tools-web-search
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelProbe.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentOpenAITests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-agent-provider-web-search.md, 2026-11-22-shared-model-rows.md, 2026-10-19-api-and-models.md]
---

# The OpenAI Agent model check uses the Responses API

## Context

In build 1720, picking `gpt-6.2-sol` in the shared LLM row showed "Agent:
Provider refused: Function tools with reasoning_effort are not supported for
gpt-6.2-sol in /v1/chat/completions". The Agent itself runs on OpenAI's
Responses API (`NativeAgentModel`), but the tool-use check in `ModelProbe`
sent one function tool to Chat Completions. OpenAI refuses function tools
there for this reasoning model, so the check failed and the Agent kept its
previous route (Anthropic). The Search row followed that real route and
showed "Anthropic · built-in" next to an OpenAI LLM row. The check has worked
this way since the shared rows; PR #414 (provider web search) did not change
it.

## Decision

- OpenAI tool use (`ModelUse.chatWithTools`, only the Agent) is checked on
  `/v1/responses` with one function tool, `store: false`,
  `max_output_tokens: 512` and no reasoning setting, the same shape as the
  Agent's request. A `completed` or `incomplete` answer passes. Plain text on
  OpenAI stays on Chat Completions, as the text features call it.
- `ModelRegistry.adapterVersion(.openAI, .chatWithTools)` is 2, so a failure
  stored by the old check is not shown again and the model is checked anew.
- OpenAI's built-in search can leave internal citation marks in model text
  (private-use characters around `cite` and `turn…`, shown as
  "citeturn138346forecast0"). `NativeAgentFinalAnswer` removes them; source
  cards still come from `sources` and the provider's citations.
- The Search row adds "Follows the Agent model: <provider> · <model>." The
  Agent can keep its own model while the LLM row shows another ("1 custom",
  or a model whose Agent check failed), and the row now says which one.

## Why

- The check must ask what the feature will ask. Chat Completions with tools
  is a request the Agent never makes, so its refusal said nothing about the
  Agent and blocked a model that works.
- Sending no `reasoning_effort` was not enough: OpenAI applies a default
  effort to this model on Chat Completions and still refuses function tools.
- Removing only private-use characters is safe: they are never meant for
  the user.

## What we tested

- Fake-provider tests: the OpenAI Agent check goes to `/v1/responses` with
  one function tool and no reasoning setting, statuses map like the other
  checks, plain text stays on Chat Completions, the new adapter version;
  citation marks removed from a Sol-like answer; an API-only search source
  (`oai-weather`, no URL) makes no link card; the Search row's Agent line.
- Live, with the maintainer's OpenAI key from Doppler, 2026-11-22, about
  $0.05 in total: the new check passes for `gpt-6.2-sol`; the Agent on
  `gpt-6.2-sol` answered the Moscow weather question after OpenAI's
  built-in search with no error and no citation marks. The weather came from
  OpenAI's weather API, which has no page URL, so that answer has no link
  cards; a raw Responses request for the same question returned page sources
  and `url_citation` annotations.
  (`NativeAgentOpenAITests`, run with `WHYTAP_LIVE_OPENAI_KEY`.)

## Rejected

- Dropping `reasoning_effort` on Chat Completions: the request has none; the
  refusal comes from the model's default effort.
- Moving the Agent check to Chat Completions without tools: it would pass
  models the Agent cannot drive.
- Inventing a link for an API-only source: there is no page to open.

2026-11-22 · orchestrator task 78 REV 2 · PR: see the branch's pull request.
