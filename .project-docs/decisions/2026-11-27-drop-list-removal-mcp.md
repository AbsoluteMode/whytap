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
- Matching as the editors match: both the request and the saved entries are
  trimmed, any letter case, so an entry restored from a backup as
  `"  Word  "` is found by `word`. Every saved spelling that matches leaves;
  the entry is reported as `removed` with its saved spelling, trimmed; a term
  that is not there is `missing` and changes nothing. A term named twice is
  one row. The result is confirmed against the whole saved list: exactly the
  named entries are gone and every other entry is unchanged.
- One invalid term (not a string, empty, more than one line, longer than the
  schema's 50 characters) removes nothing, wherever it is in the batch. The
  limit applies to the submitted string as JSON Schema counts it: code
  points, before trimming (50 spaces plus `x`, or 26 `e` with a combining
  accent, is too long although it trims or renders shorter).
  No `all`, no extra arguments, no way to clear a list.
- External harnesses only. The built-in Agent (`NativeAgentAppControl`)
  neither lists nor dispatches them (`externalOnly`), and its copies of the
  add tools' descriptions do not point at them; it keeps the add tools.
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
list untouched, the 50-character boundary for both lists, restored entries
with spaces, removal again after a restore), `AppControlDropListsScopeTests`
and `AppControlDropListsRestoredTests` (from build-queue probe 722: the
built-in Agent does not get the removal tools, an over-long term in a mixed
batch changes neither list, restored `"  Fixture  "` is removed by
`fixture`), `DropListRemoveRawLengthTests` (from build-queue probe 724:
padded and combining-mark terms over 50 code points in a mixed batch change
neither list; a padded term of exactly 50 still removes), `NativeAgentAppControlTests` (the built-in catalog is the MCP
catalog minus the two removal tools), `HarnessAccessTests` (denied and mid-request revocation
leave the entries), `AppControlMCPServerTests` and `WhytapMCPServerTests`
(catalog, annotations, descriptions).

## Rejected

- Clearing a whole list in one call: too easy to lose a curated list.
- The in-app agent's drops and its own tool wiring from PR 449: that agent is
  removed.

2026-11-27 · from PR 449 (closed)
