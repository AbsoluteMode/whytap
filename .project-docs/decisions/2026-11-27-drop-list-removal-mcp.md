---
id: drop-list-removal-mcp-2026-11-27
type: decision
title: Claude Code and Codex can remove named words from Vocab and Filler
summary: whytap_vocab_remove and whytap_filler_remove in the Whytap MCP server take 1-20 named entries out of each list through its own store, matched in any letter case without surrounding spaces. A removed entry is reported with its saved spelling, one that is not there as missing. Both need the harness's one-time Yes and are the only tools marked destructive. Carved out of the closed PR 449 without its in-app agent parts.
status: confirmed
tags: [app-control, mcp, vocab, filler, dictation, harness-access]
canonical_for: [drop-list-removal]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: 'On 2026-11-24 the maintainer said the Agent must be able to remove words from Vocab and Filler too (ORCH-TASK 96, REV 4, translated). On 2026-11-27, with the Agent moving to Claude Code or Codex (task 106), the owner, through the orchestrating session, kept only the MCP part of PR 449 for Claude Code and Codex and dropped everything tied to the in-app agent and its drops.'
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/AppControl/AppControlDropLists.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/WhytapCaseKit/AppControlMCPServer.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Tests/SidekeyTests/AppControl/AppControlDropListsRemovalTests.swift
    confirmed_at: 2026-11-27
related: [2026-11-23-agent-drop-lists.md, 2026-11-20-harness-access.md]
---

# Claude Code and Codex can remove named words from Vocab and Filler

## Context

The Whytap MCP server could add words to Vocab and Filler
([drop lists](2026-11-23-agent-drop-lists.md)) but not take one out. PR 449
added removal together with island "drops" for the in-app agent. The in-app
agent is being replaced by the user's own Claude Code or Codex (task 106,
PR 525 and PR 527), so only the MCP tools are kept.

## Decision

- Two tools, `whytap_vocab_remove` and `whytap_filler_remove`, each taking
  `terms`, 1–20 entries, through `AppControlDropLists` and the stores' own
  `remove` (`VocabularyCache`, `FillerTermsStore`).
- Matching as the editors match: trimmed, any letter case. A removed entry is
  reported as `removed` with the spelling it had; a term that is not there is
  `missing` and changes nothing. A term named twice is one row.
- One invalid term (not a string, empty, more than one line) removes nothing.
  No `all`, no extra arguments, no way to clear a list.
- The harness's one-time Yes (`HarnessAccessGate.gatedOperations`) covers
  them, and `HarnessConsent.stillAllowed` is checked again right before the
  write. The result is confirmed from the saved list.
- They are the only tools with `destructiveHint: true`; the Filler tool's
  description says that cutting a word from dictation is `filler_add`.

## Why

Users asked to take words out of the lists by asking, as they add them. The
editors' own stores keep the island editors, dictation and the tools in
agreement, and naming entries one by one keeps a mistaken request small.

## What we tested

`AppControlDropListsRemovalTests` (case and spacing, missing entries and
retry, an invalid term in the batch, duplicates, argument checks, the other
list untouched), `HarnessAccessTests` (denied and mid-request revocation
leave the entries), `AppControlMCPServerTests` and `WhytapMCPServerTests`
(catalog, annotations, descriptions).

## Rejected

- Clearing a whole list in one call: too easy to lose a curated list.
- The in-app agent's drops and its own tool wiring from PR 449: that agent is
  removed.

2026-11-27 · from PR 449 (closed)
