---
id: structured-agent-answers-2026-11-21
type: decision
title: Render structured Agent answers from Markdown
summary: Use Markdown in the existing answer string and adapt comparisons to the available island width.
status: confirmed
tags: [agent, answers, markdown, table, callouts, island, accessibility]
canonical_for: [agent-answer-markdown, adaptive-agent-tables]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the maintainer approved the structured-answer recommendation, GFM NOTE and WARNING, and the CLI prompt update in the same PR.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Agent/AgentAnswerMarkdownPrompt.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Agent/UI/Renderers/MarkdownTableView.swift
    confirmed_at: 2026-11-21
related: [2026-10-22-native-agent.md, 2026-10-22-agent-answers-and-screen.md, 2026-11-22-agent-insert-card.md, 2026-11-22-native-agent-app-control.md]
---

# Structured Agent answers

## Context and alternatives

The island renders Markdown, but the prompts encouraged a prose paragraph for
comparisons and procedures. Adding answer blocks or fields to the terminal
tool would require a new wire and history contract. Older builds can reject an
unknown block kind when they reopen the saved answer.

## Decision and rationale

Use a compact GFM subset inside the existing native `finish_answer.answer`
string and the CLI's final text. Native sources use `finish_answer.sources`;
CLI sources use link items in the existing `useful.actions` fence. Keep Markdown
in the stored answer. Older builds can still show the table and ordinary quote,
and a model that emits plain prose still produces a valid answer.

Lead with a plain conclusion and keep factual one-liners plain. Use tables for
comparisons with shared attributes, numbered lists for procedures and fences
for copyable commands and paths. Reuse the existing action cards and code
renderer. Typed NOTE and WARNING share a tinted callout treatment. Other
markers retain their quote. Numbered lists stay in the selectable text run
and keep their first number, so a list resumed after a line such as "3–4."
continues at 5 ([Insert card decision](2026-11-22-agent-insert-card.md)).

## Resolution and consequences

A grid uses up to three columns with at least 72 pt per column. At tighter
widths, present one record per row with a title and labeled values. Eight rows
are visible initially, and the disclosure reveals the remainder in place.
The prompt's length guidance imposes no renderer text limit. Completed answers
start at the top of their vertical viewport. The viewport reserves space for
the measured title and action cards inside the 480 pt island zone.

The format rules apply to resumed CLI sessions through the per-turn prompt.
The existing terminal schema, events, blocks and history remain compatible
with the [native completion decision](2026-10-22-native-agent.md). This refines
the prose-length guidance in [compact actionable answers](2026-10-22-agent-answers-and-screen.md).
