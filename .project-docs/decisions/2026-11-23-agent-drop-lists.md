---
id: agent-drop-lists-2026-11-23
type: decision
title: The Agent and the plugin add words to Vocab and Filler
summary: whytap_vocab_add and whytap_filler_add add 1-20 entries through each list's own store and checks, report existing entries in their saved form, run directly for the built-in Agent and behind the harness Yes for coding tools.
status: confirmed
tags: [agent, native-agent, app-control, vocab, filler, dictation, mcp, harness-access]
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
  - type: repository
    reference: Tests/SidekeyTests/AppControl/HarnessAccessTests.swift
    confirmed_at: 2026-11-23
related: [2026-11-22-agent-toolbox-hotkeys.md, 2026-11-20-harness-access.md, 2026-11-23-vocabulary-route-budget.md, 2026-11-27-drop-list-removal-mcp.md]
---

# The Agent adds words to Vocab and Filler

## Context

Drop has two lists the user fills by hand in the island: Vocab (names and
terms dictation sends to the speech provider so they are spelled right) and
Filler (words Drop removes from a take). The Agent could change neither: "add
whytap to vocab" got a description of the island's Vocab panel and a card to
copy the word. The maintainer asked for the Agent to do it, "not only in
Vocab but everywhere". A third list, Replace, existed only for Drop
learning; it left the app when Drop learning was shelved on 2026-11-23
(PR #428), so it is not offered. These are all the lists of this kind; To-do
already has its own operations.

## Decision

- **Two operations in the app-control catalog**, `whytap_vocab_add` and
  `whytap_filler_add`, each taking `terms`, 1–20 entries. The built-in Agent
  gets them inside its single `whytap` tool; the strict first-request test
  covers Anthropic, OpenAI and OpenRouter.
- **Each list's own store and rules.** Vocab: `VocabularyCache.add` and
  `validate` (50 characters, 1,000 terms). Filler: `FillerTermsStore.add`,
  whose checks moved into a static `validate` shared with the editor (50
  characters, 100 terms). Both post their change notifications, so an open
  island editor reloads; every take reads both lists. No defaults write of
  its own.
- **The advertised length limit on the raw term.** Both tools advertise
  `maxLength` 50 per term. Since 2026-11-28 it is checked on the submitted
  string as JSON Schema counts it, in code points before trimming, for the
  whole batch before anything changes (50 spaces plus `x`, or 26 `e` with a
  combining accent, is too long); the stores' own 50-character rule still
  applies to the trimmed term. The removal tools follow the same rule.
- **One line.** A term with a line break or a control character (category
  Cc, line and paragraph separators) is refused; format characters such as
  the zero-width non-joiner (U+200C) that Persian needs stay, as the stores
  and editors accept them.
- **An entry already there** is `existing`, in its saved spelling, and left
  alone. The Agent says so and shows no change line. Retrying is safe, so
  there is no `expected` value, as for `todo_add`.
- **Batches** are checked whole first: one invalid entry adds nothing
  (`invalid_term`); a full list answers `list_full`.
- **Coding tools need the user's Yes.** Both operations are in
  `HarnessAccessGate.gatedOperations` next to the meeting tools: they change
  the user's speech profile. Cursor, scripts and other programs get
  `unsupported_client`; Claude Code and Codex get the one-time question, and a
  No answers `access_denied`. `HarnessConsent.stillAllowed` is checked again
  right before the write, so turning access off while a request waits writes
  nothing. The built-in Agent runs them directly, and its prompt says to add
  only what the current request names.
- **No per-route promise.** An earlier version reported whether the current
  Drop route would send a term, from the account's budget. What reaches a
  provider depends on the model (`gpt-realtime-whisper` takes no prompt, OpenAI
  Live keywords drop `<` and `>`, On this Mac uses no Vocab), so that report
  could be wrong; it was removed. Each route keeps sending the part its model
  supports (`VocabularyBudget`, the adapters).
- **Filler copy.** The tool says Drop removes Filler words in Fast and Smart
  and that a Fast take the filter would empty is pasted unfiltered, which is
  Drop's existing behavior.
- **Literal spelling.** The answer is Markdown, so the app escapes its own
  change lines as Markdown literals (`NativeAgentAppControl.markdownLiteral`):
  `Vocab + __init__` renders with its underscores, and so do model IDs such as
  `scribe_v3_live` in other change lines. Step labels stay plain text.
- **Not added:** reading the lists and removing entries. They need a
  separate request.

## Why

- The same stores and checks as the editors make an Agent-added entry behave
  like a typed one in the editors, backups, settings sync and dictation.
- Vocab and Filler shape what is pasted in every dictation; a coding tool
  should not change them without the user's Yes, while the user's own request
  to the built-in Agent is that consent.
- Keeping an existing entry avoids silently changing a spelling the user chose.

## What was tested

`NativeAgentAppControlTests`, the real native loop with a stubbed model and
temporary stores: the maintainer's request, in Russian, to add whytap to
vocab (saved, an open island editor reloads it, Soniox's request includes it,
the line, the rule in the prompt); an existing word in another letter case;
several words with a duplicate inside the batch; empty, blank, 51-character,
multi-line, mixed valid and invalid, 0 and 21 terms, wrong types, unknown
fields, a full list and an existing word on a full list; a Persian word with
U+200C accepted by both lists while U+2028, a tab and a carriage return are
refused in a batch; `__init__` rendered literally by the answer's Markdown
parser and plain in the step label. Filler: a word saved, an open editor
reloaded and the next take's filter removing it; existing, too long,
multi-line, blank and a full list of 100. `HarnessAccessTests`: both writes
gated with the meeting tools, a No refused, a script in the harness shell
refused, and access turned off while a request waits writing nothing.
`DropListAddRawLengthTests`: padded, combining-mark and 49-letters-plus-spaces
terms over 50 code points after a valid term add nothing to either list; a
padded term of exactly 50 code points is added trimmed; 25 accented letters
(50 code points) are accepted; the schema limit equals both stores' limit.
Not tested: the installed app, a live model.

## Rejected

- Writing the lists' defaults keys directly: skips validation and the editors'
  reload notification.
- Replacing an existing spelling: the user's saved form wins.
- Reporting per-route sending from the account's budget: model-specific
  request shapes made it wrong; repeating the adapters' rules here would drift.
- Leaving the writes outside the harness gate like settings: a coding tool
  could change what every dictation pastes without the user's Yes.
- `whytap_replace_add`: Replace left the app with Drop learning.
- Read or delete operations now: not asked for; removal stays in the island.

2026-11-23, branch `claude/agent-vocab-add`.
