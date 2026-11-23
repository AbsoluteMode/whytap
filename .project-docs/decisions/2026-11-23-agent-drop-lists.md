---
id: agent-drop-lists-2026-11-23
type: decision
title: The Agent and the plugin add entries to Vocab, Filler and Replace
summary: whytap_vocab_add, whytap_filler_add and whytap_replace_add add 1-20 entries through each list's own store and checks, report existing entries in their saved form, and are offered to the built-in Agent and to whytap mcp.
status: confirmed
tags: [agent, native-agent, app-control, vocab, filler, replace, dictation, mcp]
canonical_for: [agent-drop-lists]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: "In build 1732 the maintainer asked the Agent to add whytap to Vocab; it answered with instructions and a copy card, and the maintainer asked for the Agent to be improved, then said it should work not only for Vocab but everywhere (orchestrator task 85, revision 1)."
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/AppControl/AppControlDropLists.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentAppControlTests.swift
    confirmed_at: 2026-11-23
related: [2026-11-22-agent-toolbox-hotkeys.md]
---

# The Agent adds entries to Drop's lists

## Context

Drop has three lists the user fills by hand or through Drop learning's
suggestions: Vocab (names and terms dictation sends to the speech provider so
they are spelled right), Filler (words Drop removes from a take) and Replace
(what Drop pastes instead of a word dictation writes). The Agent could change
none of them: "add whytap to vocab" got a description of the island's Vocab
panel and a card to copy the word. The maintainer asked for the Agent to do
it, "not only in Vocab but everywhere". These three are all the lists of this
kind: the backup's vocabulary section holds exactly them; To-do already has
its own operations.

## Decision

- **Three operations in the app-control catalog**, 1–20 entries each:
  `whytap_vocab_add` and `whytap_filler_add` take `terms`;
  `whytap_replace_add` takes `rules` of `{heard, wanted}`. The built-in Agent
  gets them inside its single `whytap` tool (Replace's nested rule objects
  live only in the arguments string, so the strict first-request limits do not
  grow); the test covers Anthropic, OpenAI and OpenRouter.
- **Each list's own store and rules.** Vocab: `VocabularyCache.add` and
  `validate` (one line, 50 characters, 1,000 terms). Filler:
  `FillerTermsStore.add`, whose checks moved into a static `validate` shared
  with the editor (50 characters, 100 terms). Replace:
  `DropReplacementStore.add` and `validate`, Drop learning's rules (heard up
  to 5 words and 50 characters, wanted up to 100, not identical, 200 rules).
  Vocab and Filler post their change notifications, so an open island editor
  reloads; every take reads all three lists. No defaults write of its own.
- **An entry already there** is `existing`, in its saved form, and left
  alone. A Replace rule for the same heard word that writes something else is
  `different` and kept with its saved `wanted`: nothing is overwritten, since
  removing or changing rules is not offered. The Agent says so and shows no
  change line. Retrying is safe, so there is no `expected` value, as for
  `todo_add`.
- **Batches** are checked whole first: one invalid entry adds nothing
  (`invalid_term`); a full list answers `list_full`.
- **Vocab route note.** `sentByCurrentDrop` applies `VocabularyBudget` to the
  current Drop route; a saved term this route cannot send gets "(no room in
  the current Drop route's limit)" in the line.
- **Prompt.** When an operation does what the user asks, the Agent does it
  instead of describing steps or giving a copy card, with one example each.
  Lines: `Vocab + whytap`, `Filler + um`, `Replace + git hub → GitHub`.
- **External harnesses.** `whytap mcp` offers the same operations. They only
  add entries the user asked for, read nothing back and remove nothing, like
  To-do; settings operations already need no prompt. One catalog keeps the
  Agent and the plugin from drifting.
- **Not added:** reading the lists and removing or changing entries. They
  need a separate request.

## Why

- The same stores and checks as the editors make an Agent-added entry behave
  like a typed one in the editors, backups, settings sync and dictation.
- Keeping an existing entry avoids silently changing a spelling or rule the
  user chose.

## What was tested

`NativeAgentAppControlTests`, the real native loop with a stubbed model and
temporary stores: the maintainer's request, in Russian, to add whytap to
vocab (saved, an open island editor reloads it, Soniox's request includes it,
the line, the rule in the prompt); an existing word in another letter case;
several words with a duplicate inside the batch; a term ElevenLabs Live
cannot send; empty, blank, 51-character, multi-line, mixed valid and invalid,
0 and 21 terms, wrong types, unknown fields, a full list and an existing word
on a full list. Filler: a filler word saved, an open editor reloaded and the
next take's filter removing it; existing, too long, multi-line, blank and a
full list of 100. Replace: a rule saved and applied by the next take's filter;
the same rule existing and a different one kept; identical sides, an empty
side, six words, 101 characters, multi-line, a mixed batch, a missing or extra
field and a plain string. Not tested: the installed app, a live model.

## Rejected

- Writing the lists' defaults keys directly: skips validation and the editors'
  reload notification.
- Replacing an existing spelling or rule: the user's saved form wins.
- One operation with a list name: Replace needs pairs, and separate schemas
  read more clearly in both the plugin and the Agent.
- Read or delete operations now: not asked for; removal stays in the island.

2026-11-23, branch `claude/agent-vocab-add`.
