---
id: agent-plain-text-cards-2026-11-27
type: decision
title: Claude Code and Codex answers get cards from their own text
summary: Links, returned paths and a single shell command in the final answer of the Agent's Claude Code or Codex become action cards, merged with the useful.actions fence, as the removed built-in agent's answers did. Only the final answer is read.
status: confirmed
tags: [agent, harness, answers, cards, insert]
canonical_for: [agent-plain-text-cards]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: On 2026-11-27 the owner, through the orchestrating session (task 106 follow-up), approved parsing links and paths in the plain answer text of Claude Code and Codex into cards like before, as a separate small PR after the built-in agent's removal.
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/AgentAnswerArtifacts.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/Agent/AskResponseStore.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Tests/SidekeyTests/Agent/AgentPlainTextCardsTests.swift
    confirmed_at: 2026-11-27
related: [2026-11-27-agent-harness-cli.md, 2026-11-22-agent-insert-card.md, 2026-11-28-agent-harness-instructions.md]
---

# Claude Code and Codex answers get cards from their own text

## Context

The built-in agent turned ordinary links, returned file or folder paths and
a one-line shell command in its final answer into keyboard-action cards
(NativeAgentAnswerArtifacts). Claude Code and Codex answers got cards only
from a trailing `useful.actions` JSON fence, which they often omit, so the
removal of the built-in agent (2026-11-27-agent-harness-cli.md) lost cards
the owner wants to keep.

## Decision

- The same detection, renamed `AgentAnswerArtifacts`, runs when a harness
  turn completes (`AskResponseStore`, at `done`), on the final answer's text
  only. Codex's intermediate messages are never read.
- Its cards merge with the fence's into one actions block: the fence's
  metadata wins for the same destination, the answer's own shell commands come
  first so Insert is preselected, duplicates collapse, at most 20 items.
- Detection is unchanged: http(s) and Markdown links; absolute and tilde paths
  in code spans, quotes, path-only fences and conservative unquoted roots; the
  one command line of a closed bash/sh/zsh/shell/fish/console/terminal fence
  (no script, continuation or heredoc; at most three). At most 32,000
  characters are scanned; no network or file I/O, nothing opens or inserts
  until the user acts. A failed turn gets no cards.

## Why

- Cards are part of the Agent's answers the owner asked to keep (task 106,
  decision 9); a fence the CLI forgets should not cost them.
- Reading only the final answer avoids cards for paths a tool merely
  mentioned while working.
- Reusing the proven detector keeps its edge cases (code, shell arguments,
  balanced parentheses) instead of writing a new one.

## What we tested

- `AgentPlainTextCardsTests`: a Claude Code result with a path and a link
  gets both cards; a fence plus text merge into one block with the command
  first and the fence's label; a Codex intermediate message adds no card; no
  cards for plain prose or after an error; a complete fence stays unchanged.
  Without the `AskResponseStore` change the first three fail.
- `AgentAnswerArtifactsTests`, ported from the built-in agent: code, URLs,
  paths with spaces, bounds and deduplication.
- Not tested live: a real Claude Code or Codex answer in the island.

## Rejected

- Parsing every Codex message: interim notes would leave stale cards.
- Asking harder for the fence in the prompt only: CLIs still omit it.

2026-11-27 · task 106 follow-up
