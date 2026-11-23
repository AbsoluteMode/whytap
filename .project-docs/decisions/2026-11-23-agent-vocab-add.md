---
id: agent-vocab-add-2026-11-23
type: decision
title: The Agent and the plugin add words to Vocab
summary: whytap_vocab_add adds 1-20 terms through VocabularyCache.add, reports existing ones with their saved spelling, and is offered to the built-in Agent and to whytap mcp.
status: confirmed
tags: [agent, native-agent, app-control, vocab, dictation, mcp]
canonical_for: [agent-vocab-add]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: "In build 1732 the maintainer asked the Agent to add whytap to Vocab; it answered with instructions and a copy card, and the maintainer asked for the Agent to be improved (orchestrator task 85)."
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/AppControl/AppControlVocabulary.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentAppControlTests.swift
    confirmed_at: 2026-11-23
related: [2026-11-22-agent-toolbox-hotkeys.md]
---

# The Agent adds words to Vocab

## Context

Vocab is the list of names and terms dictation sends to the speech provider
so they are spelled right. The Agent could not change it: "add whytap to
vocab" got a description of the island's Vocab panel and a card to copy the
word.

## Decision

- **One operation, `whytap_vocab_add`,** in the app-control catalog: `terms`,
  1–20 words or short phrases. The built-in Agent gets it inside its single
  `whytap` tool; the first-request strict limits test still covers every route.
- **The app's own path.** Terms are added with `VocabularyCache.add`, which
  Drop learning uses, with `VocabularyCache.validate`, which the island editor
  uses: one line, at most 50 characters, at most 1,000 terms, duplicates
  compared without letter case. The store posts its change notification, so
  an open Vocab editor reloads; the next take reads the list. No defaults
  write of its own.
- **A word already there** is `existing`, with the spelling saved in Vocab,
  and is left alone: no second copy, no spelling change. The Agent says it is
  already there; no change line is shown. Retrying is safe, so there is no
  `expected` value, as for `todo_add`.
- **Batches** are checked whole first: one empty, too long or multi-line term
  adds nothing (`invalid_term`); a full list answers `vocab_full`.
- **Route note.** `sentByCurrentDrop` applies `VocabularyBudget` to the
  current Drop route. A saved term that this route cannot send (ElevenLabs
  Live takes terms up to 20 characters) gets "(no room in the current Drop
  route's limit)" in the line.
- **Prompt.** When an operation does what the user asks, the Agent does it
  instead of describing steps or giving a copy card.
- **External harnesses.** `whytap mcp` offers the same operation. It only adds
  words the user asked for, reads nothing back and removes nothing, like
  To-do; settings operations already need no prompt. One catalog keeps the
  Agent and the plugin from drifting.
- **Not added:** reading the list, removing words, Filler and Replace. They
  need a separate request.

## Why

- The same store and checks as the island editor make an Agent-added word
  behave like a typed one in the editor, backups, settings sync and dictation.
- Reporting an existing word with its saved spelling avoids silently changing
  a spelling the user chose.

## What was tested

`NativeAgentAppControlTests`, the real native loop with a stubbed model and
temporary stores: the maintainer's request, in Russian, to add whytap to vocab (saved, an open island editor
reloads it, Soniox's request includes it, the line `Vocab + whytap`, the rule
in the prompt); an existing word in another letter case (reported, list
unchanged, no line); several words with a duplicate inside the batch; a term
ElevenLabs Live cannot send (saved, noted); empty, blank, 51-character,
multi-line, mixed valid and invalid, 0 and 21 terms, wrong types, unknown
fields, a full list (refused) and an existing word on a full list (reported).
Not tested: the installed app, a live model.

## Rejected

- Writing the Vocab defaults key directly: skips validation and the editor's
  reload notification.
- Replacing an existing word's spelling: the user's saved form wins.
- A Vocab read or delete operation now: not asked for; removal stays in the
  island.

2026-11-23, branch `claude/agent-vocab-add`.
