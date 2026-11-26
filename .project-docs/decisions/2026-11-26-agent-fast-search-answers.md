---
id: agent-fast-search-answers-2026-11-26
type: decision
title: A simple question with a web search is answered fast by the built-in Agent
summary: Claude Sonnet 5.5 gets thinking between_tools also beside Anthropic's web search (its own default thinking held the first byte about 9 s); several finish_answer calls alone give the first valid one; Claude citation tags are removed from answers; a simple factual question is answered in 1-3 sentences; direct Anthropic requests after a turn's first mark the tools and instructions for the prompt cache.
status: confirmed
tags: [agent, native-agent, anthropic, web-search, latency, reasoning, prompt-cache]
canonical_for: [agent-search-latency]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: "On 2026-11-26 the maintainer reported that a weather question to the Agent thought for long and asked that such questions run very fast: one search, the answer as JSON (orchestrator task 108, REV 1). The orchestrator approved the three changes and the short-answer rule."
    confirmed_at: 2026-11-26
  - type: url
    reference: https://platform.claude.com/docs/en/build-with-claude/prompt-caching
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentModel.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentMinimalReasoningTests.swift
    confirmed_at: 2026-11-26
related: [2026-11-24-agent-minimal-reasoning.md]
---

# A simple question with a web search is answered fast

## Context

After the least-reasoning change (2026-11-24) the maintainer asked the Agent
for the weather in Saint Petersburg and it "thought for long". His turn was not
in this Mac's logs, so the turn was reproduced on the real native loop with his
model, Claude Sonnet 5.5, and Anthropic's own web search (the default).

## Decision

- **Claude Sonnet 5.5 gets `between_tools` beside the provider's search too.**
  The 2026-11-24 decision left its thinking field out there, because in a
  live check 3 of 4 responses repeated `finish_answer`. Without the field its
  own default thinking held the first byte 8.7 s (8.9 s with the search tool
  removed and a 5k-token prompt, so neither the search nor the prompt size
  caused it); with `between_tools` the first byte came at 2.0-3.6 s.
- **Several `finish_answer` calls alone in one response give the first valid
  one**, and the turn ends there. A batch mixing `finish_answer` with another
  tool still fails before anything runs.
- **Claude citation tags are removed from the answer.** After a search Claude
  copied Anthropic's citation markup (`<cite index="1-9">`) into
  `finish_answer`, and in 3 of 4 answers the text stopped right after the tag.
  The system prompt now asks for plain prose with the pages in `sources`, and
  `<cite ...>` / `</cite>` are removed on Claude turns (direct or `anthropic/`
  on OpenRouter), keeping the cited words, outside code and quotes.
- **Text after the search is the answer.** When a response ran its search,
  holds the results and ends (end_turn) with text and no tool call, the text
  after the last result (without the preamble before the search) is the
  answer. Before, a second request asked for `finish_answer`; in a live pair it
  took 3.2 s more. A result deferred from an earlier response still gets that
  request. The system prompt asks for `finish_answer` in the same response.
- **A simple factual question gets 1-3 sentences**, without a table, list or
  callout (system prompt and the `answer` description). Answers to the weather
  question had grown to 530-830 output tokens with tables and NOTE callouts,
  1.5-3.5 s of writing.
- **Prompt cache from a turn's second request.** Direct Anthropic requests
  after the turn's first mark the system block (after the tools) with
  `cache_control: ephemeral`, so later steps of a multi-step task read the
  ~15k tokens of tools and instructions. A turn's first request has no
  breakpoint.
- No hard output cap below 16,384 tokens: the Agent cannot tell a weather
  question from a request for a long text before the model answers, and the
  2026-11-23 decision raised the cap for those.

## Why

- The maintainer wants a search question answered at once; the hidden default
  thinking was the largest single cost.
- The duplicate `finish_answer` that ruled `between_tools` out did not appear
  in 4 new runs, and taking the first valid call makes it harmless if it does.
- A single question would pay the cache write (1.25x input) and Anthropic's
  5-minute cache rarely meets the maintainer's next question; inside a task the
  tools and instructions repeat on every step.

## What was tested

Live, 2026-11-26, the real native loop through `swift test` with stubbed
storage and a live transport (no app launched), prompt "the weather in Saint Petersburg" (in Russian), keys
from the maintainer's own store, about $1.5 in all:

- Before: Sonnet 5.5 13.6 s and 12.8 s, one model request (Anthropic searched
  the city weather for today once, 9 results, then `finish_answer`),
  effort low, no thinking field, 0 thinking tokens reported, 23.5k input
  tokens; Haiku 5.5 (thinking disabled) 10.2 s. Streamed, same body: first
  byte 8.7 s, search 1.1 s, answer 2.3 s.
- `between_tools` beside the search, 4 runs: one `finish_answer` each, no
  duplicates; 3 answers cut at a citation tag.
- After the change, streamed: Sonnet 5.5 7.8 s (first byte 2.0 s, search
  2.2 s, answer 3.4 s); Haiku 5.5 6.7 s (2.0 s, 2.1 s, 2.3 s). The same body
  without streaming: 7.2-7.3 s from Python, 5.1-5.4 s with curl. Through the
  native loop the same request took 10.3-14.2 s (investigated separately).

`NativeAgentMinimalReasoningTests`: Sonnet 5.5 with and without the provider's
search sends `between_tools`; repeated `finish_answer` takes the first valid
call, a mixed batch and only invalid calls fail; citation tags removed on a
Claude turn and kept in code and on OpenAI; the system block is marked for the
cache only from the turn's second request. `NativeAgentLowEffortTests` and
`NativeAgentWebSearchTests` updated for the system block.

After the maintainer asked for the cause of the remaining gap, pairs of the
native loop and curl on the exact body the loop had just sent gave 10.7 s
(plus a 3.2 s second request) against 4.3 s, and 5.3 s against 6.0 s; outside
the HTTP request a turn spent about 0.1 s. The gap is Anthropic's own response
time for a search turn, which varied from 4.3 to 10.7 s for one body, not the
app.

## Rejected

- Keeping Sonnet 5.5 without a thinking field beside the search: about 9 s
  before the first byte on every search question.
- Turning the provider's search off for simple questions: a weather answer
  needs it.
- A cache breakpoint on every request: on a single question the write costs
  more than it saves.
- A low output cap for every request: it would cut long answers the Agent is
  asked for.

2026-11-26, branch `claude/agent-fast-search`.
