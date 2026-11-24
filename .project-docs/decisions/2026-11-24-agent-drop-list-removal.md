---
id: agent-drop-list-removal-2026-11-24
type: decision
title: The Agent and the plugin remove named words from Vocab and Filler
summary: whytap_vocab_remove and whytap_filler_remove take 1-20 named entries out of each list through its own store, matched in any letter case without surrounding spaces. A removed entry is reported with its saved spelling, one that is not there as missing. The built-in Agent shows "Vocab − word" as a step drop; coding tools need the harness Yes.
status: confirmed
tags: [agent, native-agent, app-control, vocab, filler, dictation, mcp, harness-access]
canonical_for: [agent-drop-list-removal]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: 'ORCH-TASK 96, REV 4, forwarded by the orchestrator on 2026-11-24. On the report that the Agent cannot remove words from Vocab or Filler the maintainer said it must be able to remove words too (translated).'
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/AppControl/AppControlDropLists.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentAppControlTests.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/AppControl/HarnessAccessTests.swift
    confirmed_at: 2026-11-24
related: [2026-11-23-agent-drop-lists.md, 2026-11-24-agent-step-drops.md, 2026-11-20-harness-access.md]
---

# Removing words from Vocab and Filler

## Context

The Agent could add words to Vocab and Filler
([drop lists](2026-11-23-agent-drop-lists.md)) but not take one out; removal
was left to the island's editors. With the step drops
([agent step drops](2026-11-24-agent-step-drops.md)) the maintainer asked
that the Agent removes words too, with a drop for the result.

## Decision

- **Two operations**, `whytap_vocab_remove` and `whytap_filler_remove`, each
  taking `terms`, 1–20 entries, in the shared catalog: the built-in Agent
  gets them inside its `whytap` tool, the plugin as MCP tools.
- **The stores' own removal.** `VocabularyCache.remove` and
  `FillerTermsStore.remove`, which the editors use: any letter case, the
  whole entry. The request's term is trimmed of surrounding spaces first.
  Both stores post their change notification, so an open editor reloads and
  the next take reads the shorter list.
- **Only named entries.** There is no "all" and no pattern; unknown
  arguments are refused, so a list cannot be cleared in one call.
- **Results.** `removed` with the spelling that was saved; `missing` for a
  term that is not in the list, which is not an error and changes nothing.
  A term named twice in one request is one row. Retrying is safe, so there
  is no `expected` value.
- **Batches** are checked whole first: an empty, multi-line or non-string
  term removes nothing (`invalid_term`, `invalid_arguments`).
- **Lines and drops.** One line per call from the saved spellings:
  `Vocab − Whytap`, `Filler − um`, `Vocab − Whytap, Exodia`, `Vocab − 4
  terms` above three. Only removed entries are in it. A call that removed
  nothing has no line, so the turn cannot end with status done and the Agent
  says in text that the word was not there. Adding and removing in one
  request are two steps in the order made.
- **Filler wording.** "Remove 'um' from my dictation" means cutting the word
  from speech, which is `whytap_filler_add`. `whytap_filler_remove` is for
  taking a word out of the list so Drop keeps it again. The tool description
  and the Agent's prompt both say so.
- **Coding tools need the user's Yes.** Both operations are in
  `AppControlDropLists.operations`, so `HarnessAccessGate` gates them with
  the additions and `HarnessConsent.stillAllowed` is checked again right
  before the write.
- **Marked destructive.** Their MCP annotations carry `destructiveHint`
  true; they are the only tools that do.
- **Not added:** reading the lists, clearing a list, Replace rules.

## Why

- The same stores as the editors keep a removed entry out of dictation,
  backups and settings sync exactly as a removal by hand does.
- `missing` instead of an error keeps a repeated request quiet and lets the
  Agent say plainly that nothing was there.
- A harness that could delete the user's speech profile without the Yes
  would be worse than one that could add to it.

## What was tested

`NativeAgentAppControlTests`, the real native loop with a stubbed model and
temporary stores: a word removed from Vocab (store, an open editor, the next
Soniox request, one step with the saved spelling, no text, the prompt
rules); a word that is not there (text, no drop, `missing`); another letter
case, surrounding spaces and a line break at the end, a phrase, Cyrillic,
the same word twice; two words in one command (one step), one present and
one missing, more than three; add and remove in one request (two steps in
order); Filler (removed, an open editor, the next take keeps the word, a
missing one); blank, multi-line, non-string, 0 and 21 terms and an unknown
argument remove nothing, and such a failure in a turn refuses done.
`HarnessAccessTests`: both removals gated, a No refused, access turned off
while a request waits removes nothing. `AppControlMCPServerTests` and
`WhytapMCPServerTests`: the two tools, their Yes and missing wording, and
that only they are marked destructive. Not tested: the installed app, a
live model.

## Rejected

- Clearing a whole list or removing by pattern: one wrong request would wipe
  a hand-built list.
- An error for a missing word: a retry or a mistyped word would look like a
  failure of the app.
- Removal outside the harness gate: see Why.
- One `*_set` operation with a mode: two plain operations read better in the
  catalog and keep additions additive.

2026-11-24 · ORCH-TASK 96 REV 4 · branch `claude/agent-vocab-remove`
