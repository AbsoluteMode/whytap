---
id: agent-provider-web-search-2026-11-22
type: decision
title: The native Agent searches with its model provider's own web search; Tavily is the fallback
summary: On Anthropic, OpenAI and OpenRouter routes the Agent sends the provider's server-side web search tool instead of requiring a Tavily key; Tavily stays for models without it or by the user's choice, and with neither the Agent says it cannot check the web.
status: confirmed
tags: [agent, native-agent, web-search, tavily, anthropic, openai, openrouter, costs]
canonical_for: [agent-web-search]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer approved ("yes, do it") moving the Agent to the provider's built-in web search with Tavily as fallback (orchestrator task 78).
    confirmed_at: 2026-11-22
  - type: url
    reference: https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool
    confirmed_at: 2026-11-22
  - type: url
    reference: https://developers.openai.com/api/docs/guides/tools-web-search
    confirmed_at: 2026-11-22
  - type: url
    reference: https://openrouter.ai/docs/guides/features/server-tools/web-search
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentWebSearch.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentWebSearchTests.swift
    confirmed_at: 2026-11-22
related: [2026-10-22-native-agent.md, 2026-10-27-anthropic-token-costs.md, 2026-11-21-free-api-report.md]
---

# The Agent searches with its model provider

## Context

The native Agent (Right Command) could search the web only through Tavily: a
separate key in API & Models → API keys. Without it a question such as "what
is the weather in Moscow today" got no search at all. All three providers the
Agent runs on now offer a server-side search tool billed on the same key:
Anthropic's web search, OpenAI's Responses `web_search` and OpenRouter's
`openrouter:web_search`.

## Decision

Each turn resolves one search (`NativeAgentWebSearch.resolve`):

1. **Built-in** when the route is Anthropic, OpenAI or OpenRouter and the model
   has it. This is the default.
2. **Tavily** when its key exists and the model has no built-in search, or the
   user turned on **Search the web with Tavily** (Settings → Other → Agent,
   `agent.native.webSearchPrefersTavily`, off by default).
3. **None** otherwise: no search tool is sent and a prompt line tells the model
   to say it could not check the web and where search is enabled.

Wire formats: Anthropic `web_search_20250305` with `max_uses: 2`; OpenAI
`{"type":"web_search"}` with `max_tool_calls: 2` and
`include: web_search_call.action.sources`; OpenRouter `openrouter:web_search`
with `max_results: 5, max_uses: 2`. The Tavily `web_search` function is left
out when the built-in tool is sent (Anthropic's server tool has the same name).

Support: Anthropic's Models API flag
`capabilities.server_tools.web_search.supported` (now stored in the catalog)
decides when present. OpenAI publishes no flag, so a short list of families
documented or known without search (`gpt-4.1-nano`, legacy GPT-3.5/4, audio,
realtime, search-preview models) uses Tavily, and a **400 on the turn's first
request** with the built-in tool retries once without it. OpenRouter's tool
works for every model (its own search or Exa).

Loop changes: Anthropic `pause_turn` and a response that searched but called
no function continue the same turn (OpenAI and OpenRouter get a short user
"Continue" message so the request does not end on the assistant). Anthropic
server blocks, including `encrypted_content`, are replayed verbatim and are not
counted against the text budget. A `finish_answer` sent beside an Anthropic
search whose result has not arrived yet gets a tool result asking to wait.

Sources: the model still puts them in `finish_answer.sources`. When it lists
no link, up to five provider citations (then search results) become link
cards, so a search answer always shows where it came from.

Costs: Anthropic's estimate adds $0.01 per
`usage.server_tool_use.web_search_requests` (only when the token price is
known, otherwise the whole estimate stays unknown); OpenRouter's reported
`usage.cost` already includes search; OpenAI reports no charge and stays
unavailable, never 0.

## Why

- The Agent's most common "current facts" question worked only after the user
  found and connected a second service. The provider already has the user's
  key, billing and privacy terms.
- Default built-in, Tavily as a switch: one obvious path, and a free option
  (Tavily's 1,000 monthly credits) for users who prefer it.
- Anthropic's basic tool version stays ZDR-eligible and works with the
  existing `anthropic-version: 2023-06-01`; dynamic filtering (`_20260209`+)
  would need programmatic tool calling or `allowed_callers` and loses ZDR.
- A first-request 400 has run and billed nothing, so one retry is safe and
  keeps a model without search usable. Later errors are not retried: a retry
  could repeat paid work or actions.
- Fallback source cards: built-in search results reach the model inside the
  provider, so without them a model that forgot `sources` would hide its
  evidence; Tavily's results were always in its own tool result.

## What we tested

- Fake-provider scenarios in `NativeAgentWebSearchTests`: Anthropic without
  Tavily (pause_turn, verbatim encrypted replay, citation cards, cost with the
  search fee), a catalog-unsupported model falling back to Tavily, a rejected
  first request retrying once with Tavily, a later rejection not retried, no
  search at all (no tool, honest prompt line, unverified answer), a provider
  search error and a Tavily timeout, OpenAI and OpenRouter request shapes,
  OpenAI continuation after a search without a function call, model sources
  winning over provider citations, settings persistence and backup.
- Not verified live: no paid request was made. In particular OpenAI's replay
  of `web_search_call` items with `store: false`, OpenRouter's server tool on
  Chat Completions with `tool_choice: "required"`, and the exact shape of
  OpenRouter's usage details are documented incompletely. The acceptance step
  checks Anthropic live; OpenAI and OpenRouter need their own live check.

## Rejected

- Keep Tavily mandatory: the reason for this change.
- OpenRouter `:online` / `plugins: [{id: "web"}]`: deprecated by OpenRouter.
- Anthropic `web_search_20260318` with dynamic filtering: needs a newer API
  version and code execution or `allowed_callers`, not ZDR-eligible.
- Probing OpenAI support with a paid test search: no free signal exists; the
  first-request 400 fallback costs nothing.
- Remembering a rejected model for later turns: a 400 can have other causes;
  a per-turn retry is cheap and never sticks a wrong state.
- Showing a guessed OpenAI search cost: the provider reports none; unknown
  stays unknown.

2026-11-22 · orchestrator task 78 · PR: see the branch's pull request.
