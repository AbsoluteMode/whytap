---
id: agent-provider-web-search-2026-11-22
type: decision
title: The native Agent searches with its model provider's own web search; Tavily is the fallback
summary: On Anthropic, OpenAI and OpenRouter routes the Agent searches with the provider's server-side web search tool by default; a Search row in API & Models → Models shows and picks the search (built-in or Tavily), Tavily serves models without built-in search, and with neither the Agent answers in one line how to turn search on. Fallback to Tavily needs positive evidence; the search budget is per turn.
status: confirmed
tags: [agent, native-agent, web-search, tavily, anthropic, openai, openrouter, costs]
canonical_for: [agent-web-search]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer approved ("yes, do it") moving the Agent to the provider's built-in web search with Tavily as fallback (orchestrator task 78).
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer clarified that when search works without Tavily, Tavily is not used by default, and then agreed to a Search row on the Models screen beside Speech and LLM ("I would add search here"); Tavily stays for models without built-in search and for own servers should they become Agent routes (orchestrator task 78, REV 1).
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

1. **Tavily** when the user picked it in **API & Models → Models → Search**
   (`agent.native.webSearch = tavily`) and its key exists.
2. **Built-in** (the default) when the route is Anthropic, OpenAI or
   OpenRouter and the model has it. The Tavily function is then not offered,
   and a call to it gets an "unavailable" tool result without reaching
   Tavily: a saved key alone never replaces built-in search.
3. **Tavily** when its key exists and the model has no built-in search.
4. **None** otherwise: no search tool is sent and a prompt line asks the
   model, when the user wants a search or current facts, to answer in one line
   that search is off for this model and that a Tavily key in API keys turns
   it on.

The **Search** row sits under Speech and LLM on the Models screen
(`AgentSearchRow`). It shows the resolved search ("Anthropic · built-in",
"OpenAI · built-in", "OpenRouter · web", "Tavily", "Off — add a Tavily key")
with its price, and a menu like theirs: the Agent model's built-in search or
Tavily (or "Add a Tavily key…"). Off draws the setup contour. Saving or
removing the Tavily key notifies the row.

Wire formats: Anthropic `web_search_20250305` with `max_uses: 2`; OpenAI
`{"type":"web_search"}` with `max_tool_calls: 2` and
`include: web_search_call.action.sources`; OpenRouter `openrouter:web_search`
with `max_results: 5, max_uses: 2`. The Tavily `web_search` function is left
out when the built-in tool is sent (Anthropic's server tool has the same name).

Budget: at most two built-in searches per turn, whatever the number of
requests. Anthropic counts `max_uses` across its own turn (pause_turn and
tool_result continuations), so its tool stays unchanged there; a new provider
turn (the app's "Continue" message) gets what is left. OpenAI
(`max_tool_calls`, every `web_search_call` action) and OpenRouter (`max_uses`,
which non-Anthropic native engines ignore) get the remainder per request, and
the tool is dropped once it is spent. Any provider web work without a
function call (an OpenAI `open_page`, OpenRouter
`usage.server_tool_use_details.web_search_requests` without citations,
Anthropic `end_turn` after a search) continues the turn; only `pause_turn` is
replayed verbatim, the rest add the "Continue" user message because current
Claude models reject prefill.

Fallback evidence: a first-request 400 moves to Tavily only on evidence
specific to the search tool (`ErrorShape.refusesWebSearch`; a flag, the text
is never kept). An ambiguous error stays on the selected route, because the
retry is what can send the query to another service. Builder review #429,
#431 and #433 showed that keyword windows keep matching quoted user text and
other tools' errors, so the rule is now structural:
- only the provider's own `message` is read (OpenRouter's `metadata.raw`
  quotes upstream text), and only when the request carried a search tool;
- a typed error (any OpenRouter `error_type`, an OpenAI `code` other than
  unsupported/invalid value, unsupported parameter, tool not supported) is
  about something else;
- a location decides: `param` or a leading `messages[0]:` / `tools.3.type:`
  path must be the search tool itself or its `type` at its own index in
  `tools`, and the error must still refuse it (`unsupported_value`,
  `tool_not_supported` or a refusal word); one of its options (`max_uses`,
  `search_context_size`: builder #436), a message, input or another tool's
  index never qualifies;
- otherwise quoted text is removed (a quoted tool identifier such as
  `'web_search'` stays), size or context wording disqualifies, and the tool's
  identifier must sit in one clause with the refusal ("Tool 'web_search' is not
  supported", "does not support tool types: web_search_20250305"), or the
  message must open with an account or model policy ("Web search is disabled
  for this organization"). The plain words "web search" elsewhere in a message
  never count. An Anthropic `web_search_tool_result` that arrives after
its `server_tool_use` (search beside a function call) also counts as web work
and continues to an answer, without counting the search twice.

Support: Anthropic's Models API flag
`capabilities.server_tools.web_search.supported` (now stored in the catalog)
decides when present; capabilities decode independently, and the same flag
(`AgentSettingsStore.selectedWebSearchSupport`) feeds the next turn and the
Search row even when the catalog gives no token limits. OpenAI publishes no flag, so a short list of families
documented or known without search (`gpt-4.1-nano`, legacy GPT-3.5/4, audio,
realtime, search-preview models) uses Tavily, and a **400 on the turn's first
request** that names the web search tool retries once without it. OpenRouter's tool
works for every model: an `anthropic/` model keeps the default engine
(Anthropic's own search, which honors `max_uses`), every other model gets
`engine: "exa"`, which OpenRouter runs and caps before a search executes;
other native engines ignore `max_uses`, and OpenRouter documents no other cap
that bounds them before they run (`max_tool_calls` is not stated to cover
native search). A workspace whose locked Server Tools policy leaves Exa out
refuses that first request with 403 before anything runs (builder #433). The
turn then retries once without the search tool, like a refusal: Tavily when
its key exists (bounded by Whytap), else no search and a text answer. An
unbounded search tool is never sent (builder #436). Tavily is reached only if
the retry succeeds, which shows the 403 was the search tool; a key or account
403 fails again on the retry and is shown as before. Searches count from
`usage.server_tool_use_details.web_search_requests`, else
`tool_calls_executed` (search is the only server tool sent), else citations.

Loop changes: Anthropic `pause_turn` and a response with web work but no
function call continue the same turn (see Budget). Anthropic
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
- The maintainer's rule: if search works without Tavily, Tavily is not used
  by default. A visible Search row next to Speech and LLM says what is used and
  what it costs, and keeps the choice where other models are chosen; Tavily
  keeps models without search useful. Own servers are not Agent routes today
  (OpenCodeModelProvider has Anthropic, OpenAI and OpenRouter only); if they
  become one, Tavily is their search.
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
  search at all (no tool, honest prompt line, unverified answer), Tavily never
  called on a built-in route even with a key unless picked, the Search row's
  labels, prices and menu, the row following the Agent route, Tavily key and
  pick in the view model, a provider
  search error and a Tavily timeout, OpenAI and OpenRouter request shapes,
  OpenAI continuation after a search without a function call, model sources
  winning over provider citations.
- Builder fixtures from reviews #429, #431 and #433 kept as tests
  (`NativeAgentWebSearchReviewTests`): refusal classification in all three
  response shapes (quotes, neighboring terms, another tool's index, a message
  location, typed errors, real refusals), and on the wire no Tavily request
  for any of them; an OpenRouter workspace that locks out Exa answers after
  one 403 and a retry without the search tool (Tavily only with its key),
  while an allowed workspace keeps Exa in one request and a repeated 403 is
  shown as a key error; a 400 on one of the search tool's options keeps the
  route on all three providers.
- Not verified live: no paid request was made. In particular OpenAI's replay
  of `web_search_call` items with `store: false`, OpenRouter's server tool on
  Chat Completions with `tool_choice: "required"`, and the exact shape of
  OpenRouter's usage details are documented incompletely. The acceptance step
  checks Anthropic live; OpenAI and OpenRouter need their own live check.

## Rejected

- A "Search the web with Tavily" switch in Settings → Other → Agent (first
  version of this PR): replaced by the Search row, where models are chosen.
- Never letting the user pick Tavily on a built-in route (second version):
  the Search menu works like Speech and LLM, so both choices are offered.
- Removing Tavily: it is the only search for models without built-in search,
  and the planned one for own servers.
- Falling back to Tavily on any first-request 400, or on any 400 that merely
  names web search (builder reviews #429, #431): a context length or prompt
  error quoting the user's words would move the query to another service.
- A 60-character window around the tool name, or any `param` that starts
  with `tools` (#431 version): quoted text and another tool's validation error
  still matched (builder #433).
- OpenRouter's default engine for every model: non-Anthropic native engines
  ignore `max_uses`, so one request could exceed the turn's two searches.
- Exa pinned with no way out (#431 version): a locked workspace without Exa
  refused every Agent request with 403, shown as a bad key (builder #433).
- Retrying an OpenRouter 403 with the workspace's own engine (#433 version):
  a non-Anthropic native engine ignores `max_uses`, so one request could run
  more than the turn's two searches (builder #436).
- Sending OpenRouter's request-level `max_tool_calls` as the cap: its support
  on Chat Completions and its effect on native engines are not documented.
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
