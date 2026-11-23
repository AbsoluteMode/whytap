---
id: agent-low-effort-2026-11-23
type: decision
title: The built-in Agent asks Anthropic and OpenAI models for low effort
summary: Direct Anthropic requests send output_config.effort low and direct OpenAI Responses requests send reasoning.effort low, only to models documented to take it; a plain-text Anthropic reply is the answer, the direct output cap is 16,384 tokens with a 180-second wait, a cut answer says so, and diagnostics record the effort and token usage. OpenRouter is unchanged.
status: confirmed
tags: [agent, native-agent, anthropic, openai, effort, latency, diagnostics]
canonical_for: [agent-effort]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: "The maintainer reported that the Agent thinks for a while before answering a simple question such as 160 times 120, and after a council review chose low effort for the Agent on Anthropic and OpenAI (orchestrator task 88)."
    confirmed_at: 2026-11-23
  - type: url
    reference: https://platform.claude.com/docs/en/build-with-claude/effort
    confirmed_at: 2026-11-23
  - type: url
    reference: https://platform.claude.com/docs/en/api/models/retrieve
    confirmed_at: 2026-11-23
  - type: url
    reference: https://developers.openai.com/api/docs/guides/reasoning
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentEffort.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentLowEffortTests.swift
    confirmed_at: 2026-11-23
related: [2026-10-22-native-agent.md, 2026-11-22-openai-agent-probe-responses.md, 2026-11-22-agent-provider-web-search.md]
---

# The built-in Agent asks for low effort

## Context

A simple question to the built-in Agent ("160 times 120") took noticeably
long. Requests went without any effort or reasoning setting, so each model
used its default: high on Claude Sonnet 5.5 and Fable 5.2 (adaptive thinking
on most requests), medium on Opus 5.5, Haiku 5.5 and current OpenAI reasoning
models. The answer is not streamed, so the island shows nothing until the
whole response, thinking included, is done. Whether the model thought on that
question was not provable: thinking tokens were not logged. The maintainer
chose low effort for the Agent on Anthropic and OpenAI.

## Decision

- **What is sent** (`NativeAgentEffort`), on every request of a turn:
  - direct Anthropic Messages: `output_config: {effort: "low"}`. The Models
    API flag `capabilities.effort.low.supported` decides when the catalog
    states it (`false` also when `effort.supported` is false). Without it, the
    families the effort page lists on 2026-11-23: Fable 5.x, Mythos 5.x and
    Preview, Opus 5.x and 4.5 to 4.8, Sonnet 5.x and 4.6, Haiku 5.5, matched by
    ID prefix (aliases and dated IDs). Other models (Sonnet 4.5, Haiku 4.5 and
    older) get no field.
  - direct OpenAI Responses: `reasoning: {effort: "low"}` on reasoning models
    (GPT-5 and later, o1, o3, o4). Chat snapshots (`-chat`), pro models (which
    may take only high), `o1-mini` and `o1-preview` get no field. OpenAI
    publishes no per-model flag in its list; current reasoning models refuse
    only `none` or `minimal`, not `low`.
  - Thinking itself is not set: the model's adaptive thinking stays, and low
    effort lets it skip thinking on simple requests.
- **Plain-text answers on Anthropic.** Direct Anthropic runs with
  `tool_choice: auto` (forced tool choice is refused), and at low effort a
  short answer often comes as plain text instead of `finish_answer`. That text
  is now the answer: it goes through the same `NativeAgentFinalAnswer` checks
  (nonempty, not a bare link list, length) as status answered with no cards,
  is saved to the conversation, and app-owned change lines still come first.
  An unanswered search keeps it invalid. OpenAI (required tool choice) cannot
  produce it; OpenRouter keeps the structured-only rule.
- **Output cap and wait.** Direct Anthropic and OpenAI requests allow 16,384
  output tokens (thinking plus answer; a lower catalog limit wins) instead of
  8,192, and a request may wait 180 seconds for its first bytes, the turn's
  own limit, instead of 60: a non-streamed answer sends nothing until it is
  complete. OpenRouter keeps 8,192 and 60 seconds.
- **A cut answer says so.** Anthropic `stop_reason: max_tokens` and OpenAI
  `status: incomplete` with `max_output_tokens` show "The answer reached the
  model's output limit. Ask for a shorter answer or split the task." instead
  of the generic failure. Nothing partial is shown.
- **Diagnostics.** The existing native-agent log events gain the requested
  effort (`low` or none) and the response's token counts: input, output,
  thinking (Anthropic `output_tokens_details.thinking_tokens`, OpenAI and
  OpenRouter `reasoning_tokens`) and cache reads and writes, on accepted and
  rejected responses. Elapsed time was already there. Counts only.
- **Not changed:** OpenRouter, the local CLI agents (Claude Code, OpenCode),
  Drop Smart, translation, meetings; the model and provider are never switched
  automatically. Streaming, prompt caching, connection warm-up, local
  arithmetic and a turn trace were proposed by the council and not confirmed.

## Why

- The effort pages of both providers recommend low for latency-sensitive chat
  and short tool tasks; effort applies to all output, so tool calls stay but
  get terser.
- Sending the field only where documented avoids an HTTP 400 on a model that
  does not take it; that model keeps its previous behavior.
- Low effort makes a plain-text reply likelier on Anthropic; rejecting it
  would turn the fastest answers into errors.
- Thinking and answer share one cap; a long answer after some thinking could
  hit 8,192, and a long non-streamed answer could pass 60 seconds of silence.

## What was tested

`NativeAgentLowEffortTests`, the real native loop against stubbed providers:
the simple question on Sonnet 5.5 (one request, effort low, no thinking field,
max_tokens 16,384, 180-second timeout, plain reply shown and saved, usage in
the accepted event without text); blank and link-only plain replies still
fail, and OpenRouter still rejects plain text; a tool question on Opus 5.5
(tool runs, both requests low); OpenAI reasoning models get
`reasoning.effort` low with required tool choice while gpt-4.1,
gpt-5-chat-latest and gpt-5-pro get none; Anthropic models by catalog flag and
by family, OpenRouter unchanged (8,192, 60 seconds, no effort); a 20,000-character
answer and a lower model limit; a cut answer on both routes with its usage;
the Models API flag parsing; usage fields of each provider.
`NativeAgentAppControlTests`: on Anthropic at low effort the whytap tool still
adds a Vocab word and the plain reply after it keeps the change line. Not
tested: a live model, the installed app, how much faster the answer is.

## Rejected

- Medium effort by default: the maintainer chose low.
- `thinking: {type: "between_tools"}` or disabled thinking: not asked for;
  low effort already lets the model skip thinking on simple questions.
- Sending effort to every model and retrying without it on HTTP 400: a paid
  failed request first; the documented list and the catalog flag avoid it.
- A repair request when the model answers in plain text: another paid round
  trip for the same answer.
- Showing a cut answer's partial text: it may stop mid-sentence or inside a
  card; the message says what to do.
- Changing OpenRouter's request: outside this task.

2026-11-23, branch `claude/agent-low-effort`.
