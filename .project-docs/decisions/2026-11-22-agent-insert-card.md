---
id: agent-insert-card-2026-11-22
type: decision
title: Agent answers lead with an Insert card for text and commands
summary: A required finish_answer.insert_text field becomes the first, preselected Insert card; shell fences are the fallback and links come last.
status: confirmed
tags: [agent, answers, actions, insert, commands, markdown]
canonical_for: [agent-insert-card, agent-card-order]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer reported that the Agent rephrased text without offering to insert it, and answered "how to update Codex" with website links instead of first offering the command to insert. The same report showed a numbered list restarting at 1 after a "3–4." item.
    confirmed_at: 2026-11-22
  - type: commit
    reference: 6bc1cd8a2cf73736c77492a800309246f552092f:Sources/Sidekey/AgentDaemon/NativeAgentFinalAnswer.swift
    confirmed_at: 2026-11-22
  - type: commit
    reference: 6bc1cd8a2cf73736c77492a800309246f552092f:Sources/Sidekey/AgentDaemon/NativeAgentAnswerArtifacts.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Agent/UI/Renderers/RendererSupport.swift
    confirmed_at: 2026-11-22
related: [2026-11-21-structured-agent-answers.md, 2026-11-27-agent-plain-text-cards.md]
---

# Agent answers lead with an Insert card

## Context

The island already had insert-only copy cards and preselects the first card
with its Insert hint. The Agent rarely produced one, for four reasons in code:

- `finish_answer.actions` described copy items as "copyable snippets" and
  asked for an empty list "when none are needed"; the prompt only said "Use
  copy items for snippets". Nothing told the model that a copy card pastes
  into the field the user came from, so a rewrite of selected text ended as
  plain answer text.
- The validated final put sources before actions, so links were the first,
  preselected card.
- The fallback that rescues missing cards skipped every code fence. A command
  in a `bash` fence never became a card.
- `MarkdownBlockParser` dropped the list's start number. "3–4." is not a list
  marker, so it ends the list; the next list ("5.") was drawn from 1.

## Decision

1. `finish_answer` gets `insert_text`, a required string in the strict schema:
   the ready-to-paste result. The model must decide on it every turn instead
   of remembering an optional array item. It becomes a copy card without a
   description (the chip shows the text), placed first and therefore
   preselected. A missing or null value is accepted as none, because Claude
   routes use auto tool choice and lax endpoints may drop fields; rejecting the
   whole answer would be worse. One enclosing Markdown fence is unwrapped so a
   command does not paste backticks.
2. The system prompt states what the card does and when to fill it: the full
   result for rewrite, shorten, translate, fix or reformat of selected or
   pasted text, or a requested message; the exact command for "how do I
   install/update/run X", which the answer leads with in a `bash` fence and
   checks against evidence; empty for plain questions. Further commands go to
   copy actions.
3. Card order is the explicit insert text, then the answer's own shell
   commands in answer order, then the model's other copy actions, paths and
   sources. When a lax endpoint drops `insert_text`, the command the answer
   leads with is therefore preselected, not an alternative the model listed
   as a copy action (builder regression on ticket 377: Homebrew in the answer,
   npm as an alternative card). A command the model also listed keeps its
   label. `NativeAgentAnswerArtifacts` keeps copy cards before paths and links
   on every path.
4. Fallback: a closed shell fence (`bash`, `sh`, `zsh`, `shell`, `fish`,
   `console`, `terminal`) with exactly one command line becomes a copy card,
   at most three. A `$ ` or `% ` prompt and comments are dropped; several
   commands, a trailing `\` or a heredoc are a script and get no card. URLs
   and paths inside the fence still stay code.
5. Ordered lists keep the first marker's number (`.orderedList(items, start:)`);
   `)` is accepted as a delimiter. The answer prompt asks for one step per
   number.

## Tested

Synthetic provider scenarios (`NativeAgentInsertCardTests`): a rewrite of
selected text ends with the Insert card preselected; "how to update Codex"
puts `npm install -g @openai/codex@latest` before the links and a Homebrew
alternative; a final without the field still gets the command from its `bash`
fence; a plain question and a follow-up without text get no copy card. The
renderer test covers "1. / 2. / 3–4. / 5. / 6.". Model compliance itself is
not provable offline; the required field and the fallback are the guards.

## Rejected

- Prompt wording alone: the old optional array already allowed copy cards and
  the model skipped them.
- Turning the whole answer into an Insert card whenever text was selected: a
  question about the selection would get a wrong card.
- Guessing commands in unlabeled fences: config and output examples would
  become cards.
- Showing the literal "3–4." as a list marker: CommonMark has no range marker;
  keeping the start number fixes the wrong renumbering without a new syntax.

2026-11-22, branch claude/agent-insert-actions.
