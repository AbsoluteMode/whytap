---
id: agent-minimal-reasoning-2026-11-24
type: decision
title: The built-in Agent asks for the least reasoning its model accepts
summary: The built-in Agent sends the lowest reasoning setting its model takes, from the tables Drop Smart uses - OpenAI none, minimal or low; Anthropic low effort with thinking off on Claude Haiku 5.5 and Claude Sonnet 5 and between_tools on Claude Sonnet 5.5; OpenRouter off or the lowest level of its catalog entry. In a turn with the provider's own web search OpenAI minimal becomes low and Claude Sonnet 5.5 keeps its own thinking. A 400 that names a reasoning setting is repeated once without the fields.
status: confirmed
tags: [agent, native-agent, anthropic, openai, openrouter, effort, reasoning, latency, diagnostics]
canonical_for: [agent-reasoning]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: "On 2026-11-24 the maintainer asked for the lowest reasoning level on the Agent too, and confirmed the plan put to him: OpenAI none or minimal, Anthropic thinking off where possible, OpenRouter reasoning off (orchestrator task 108)."
    confirmed_at: 2026-11-24
  - type: url
    reference: https://platform.claude.com/docs/en/build-with-claude/effort
    confirmed_at: 2026-11-24
  - type: url
    reference: https://platform.claude.com/docs/en/build-with-claude/extended-thinking
    confirmed_at: 2026-11-24
  - type: url
    reference: https://developers.openai.com/api/docs/guides/reasoning
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentEffort.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentMinimalReasoningTests.swift
    confirmed_at: 2026-11-24
related: [2026-11-23-agent-low-effort.md, 2026-11-24-smart-minimal-reasoning.md]
---

# The built-in Agent asks for the least reasoning

## Context

Since 2026-11-23 the Agent asked direct Anthropic and OpenAI models for low
effort and left OpenRouter alone
([agent low effort](2026-11-23-agent-low-effort.md)). On 2026-11-24 Drop Smart
went further: the lowest level each model accepts, thinking off where the
model allows ([Smart minimal reasoning](2026-11-24-smart-minimal-reasoning.md)).
The maintainer asked for the same on the Agent, on all three routes.

## Decision

`NativeAgentEffort.request` builds the fields for every request of a turn from
the tables Smart uses; nothing is duplicated.

- **Direct OpenAI (Responses), `reasoning.effort`** from
  `SmartDirectReasoning.openAIEffort`: `none` on GPT-5.1, 5.2, 5.4, 5.5, 5.6,
  GPT-6 Luna, GPT-6 Sol and GPT-6.1 Terra; `minimal` on GPT-5, GPT-5 mini and
  GPT-5 nano; `low` on every other reasoning model. Chat snapshots, pro models
  and pre-reasoning models get no field, as before.
- **Direct Anthropic (Messages)**: `output_config.effort: low` as before (the
  Models API flag wins, else the effort page's families), plus `thinking.type`
  from `SmartDirectReasoning.anthropic`: `disabled` on Claude Haiku 5.5 and
  Claude Sonnet 5, `between_tools` on Claude Sonnet 5.5 (it refuses
  `disabled`). Fable, Mythos and Claude Opus 5.5 cannot turn thinking off.
  Claude Opus 5 could, but Anthropic documents that it then may write a tool
  call or thinking tags into its visible text: it keeps low effort only. Opus
  4.5 to 4.8 and Sonnet 4.6 do not think unless asked.
- **OpenRouter (Chat Completions), `reasoning`** from the model's catalog
  entry (`OpenRouterReasoningCapabilities.dictationSetting`, the rule Smart
  and the model probe use): `{enabled: false}` where reasoning is optional,
  else `{effort: <lowest listed>}`. The entry comes from the saved catalog
  (`AgentRunOptions.openRouterReasoning`), with no request for it. No entry,
  no field.
- **A turn with the provider's own web search steps up one level** where the
  lowest one does not work with it. The choice is made at the turn's first
  request and kept for the turn (a thinking setting must not change inside a
  tool loop):
  - OpenAI answers HTTP 400 to `minimal` beside its `web_search` tool ("The
    following tools cannot be used with reasoning.effort 'minimal':
    web_search"): `low` is sent. The same step is taken on OpenRouter when the
    entry lists `low`. `none` works with the search tool.
  - Claude Sonnet 5.5 with `between_tools` answered a search with several
    identical `finish_answer` calls in one response (see below), which the
    Agent rejects: no `thinking` field is sent and low effort stays, as before
    this change.
  The provider's search is on by default for models that have it, so in the
  default setup GPT-5, GPT-5 mini, GPT-5 nano and Claude Sonnet 5.5 behave as
  they did on 2026-11-23; they get the lower setting when the Agent's search
  is Tavily or the model has none.
- **A refused request goes once more without the fields.** When the provider
  answers HTTP 400 and its error names a reasoning setting (`reasoning`,
  `thinking`, `effort` or `output_config` in the message, the `param`, or the
  upstream text OpenRouter quotes: `ErrorShape.namesReasoning`), or OpenRouter
  answers 404 (no endpoint supports the requested parameters), the same
  request is sent again without the reasoning fields. Only an accepted answer
  to that repeat marks the model (`NativeAgentEffort.refusals`, in memory
  until relaunch, apart from Smart's list): later turns send it no fields.
  The model did not run on the refused request, so nothing is repeated or
  paid twice, and the refused request is not counted as usage. Any other
  failure, an unrelated 400 included, is not repeated: the rule that a
  model or tool request is never retried stays.
- **Diagnostics.** The `native-agent` events carry the level asked for
  (`none`, `minimal`, `low` and higher, or `off` for OpenRouter's
  `enabled: false`), the Anthropic `thinking` setting (`disabled`,
  `between_tools`), `effortRetry` on the repeat's events and `namesReasoning`
  on an error. Fixed names and flags only, never provider text.
- **Not changed:** the output cap, the wait, plain-text answers and cut-answer
  messages of the 2026-11-23 decision; the local CLI agents; translation and
  meetings; the model and provider are never switched.

## Why

- The maintainer chose the lowest level for the Agent, knowing it trades
  depth for speed.
- One table per provider keeps Smart and the Agent in step when a model
  family is added.
- Stepping up beside the provider's search avoids a refused first request on
  every turn (OpenAI) and a failed turn (Claude Sonnet 5.5).
- The refusal repeat needs positive evidence because the Agent's requests
  can be large and its tool loop must not repeat a model call for an
  unrelated error; the web search fallback follows the same rule.

## What was tested

Live, 2026-11-24, about 30 short synthetic requests with two function tools
(`get_time`, `finish_answer`), keys from the maintainer's own store:

- OpenAI Responses, `tool_choice: required`: GPT-5.5 and GPT-6 Luna at `none`
  and GPT-5 mini at `minimal` called the tool, took its result and finished
  (0 reasoning tokens). GPT-5 and GPT-5 mini at `minimal` with `web_search`:
  HTTP 400 with the message quoted above. GPT-5.5 at `none` with `web_search`:
  searched and finished.
- Anthropic Messages, `tool_choice: auto`, low effort: Claude Sonnet 5.5 with
  `between_tools`, Claude Haiku 5.5 and Claude Sonnet 5 with `disabled` called
  the tool, took its result and finished (0 thinking tokens). With the
  `web_search` server tool: Haiku 5.5 (3 of 3) and Sonnet 5 (2 of 2) searched
  and finished once. Sonnet 5.5 with `between_tools`: 3 of 4 responses held
  several identical `finish_answer` calls, each cut at a citation tag, one
  running to the output limit; without the `thinking` field, 2 of 2 finished
  once.
- OpenRouter was not tested live (the stored key was refused, HTTP 401). Its
  catalog on that day lists reasoning as mandatory for
  `anthropic/claude-sonnet-5.5` (lowest `low`) and `openai/gpt-5-mini`
  (lowest `minimal`), and optional for `openai/gpt-5.5` and
  `anthropic/claude-haiku-5.5`.

`NativeAgentMinimalReasoningTests`, the real native loop against stubbed
providers: a Haiku 5.5 tool turn with thinking off on both requests and its
stored events; Sonnet 5.5 with and without the provider's search; the table
per Anthropic model; OpenAI levels with and without the search tool;
OpenRouter optional, mandatory, `minimal` beside search, and no entry; the
catalog entry reaching the turn from Settings; a refused request repeated
once on each route, the next turn sending no fields and another model
unaffected; a 400 that names thinking but fails again, and an HTTP-200
non-answer on the repeat, not marking the model; 401, 429, 500, an unrelated
400 and an unreadable 400 not repeated. `NativeAgentLowEffortTests` updated
for the new levels. Not tested: the installed app, how much faster answers
are, OpenRouter live.

## Rejected

- `between_tools` on Claude Sonnet 5.5 in every turn: it broke answers after
  a provider search in the live check.
- Dropping the provider's search to keep `minimal` or `between_tools`: search
  matters more to an answer than the last step of reasoning.
- Thinking off on Claude Opus 5: Anthropic documents tool calls written as
  text and leaked thinking tags.
- Repeating on any HTTP 400, as Smart does: a large Agent request would be
  sent twice for an unrelated error, against the no-retry rule.
- A request for OpenRouter's catalog before a turn: the saved catalog already
  has the entry.
- Sharing Smart's refusal list: the two features send different fields
  (Smart never sends a search tool), so one must not switch the other off.

2026-11-24, branch `claude/agent-minimal-reasoning`.
