---
id: vocabulary-route-budget-2026-11-23
type: decision
title: One Vocab list up to 1,000 terms; each request sends the part its route accepts
summary: The saved Vocab list holds up to 1,000 terms of up to 50 characters instead of a global 50 x 20 cap, and each request takes, in list order, what its provider accepts (VocabularyBudget). It came with Drop learning (PR #406) and stays in main when that feature was shelved, because it is manual Vocab behaviour and lists already longer than 50 must not reach providers untrimmed.
status: confirmed
tags: [vocab, providers, streaming, meetings]
canonical_for: [vocabulary-budget]
verified_at: 2026-11-23
sources:
  - type: repository
    reference: Sources/Sidekey/Settings/VocabularyBudget.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Settings/VocabularyBudgetTests.swift
    confirmed_at: 2026-11-23
  - type: commit
    reference: 640e123c
    confirmed_at: 2026-11-23
  - type: user-confirmed
    reference: ORCH-TASK 72, REV 25 forwarded by the orchestrator. The user asked to take Drop learning out of the app into a branch ("too raw ... put it in a box for now", translated) and not to touch manual Vocab and Filler.
    confirmed_at: 2026-11-23
related: [2026-11-21-recorded-meeting-models.md, 2026-11-23-drop-learning-shelved.md, 2026-11-23-agent-drop-lists.md]
---

## Context

Until PR #406 the Vocab list was capped at 50 terms of 20 characters, the
strictest provider's limit (ElevenLabs Scribe Live), so every provider got
the whole list. Drop learning needed room to add terms, so PR #406 made the
limit per route. On 2026-11-23 Drop learning was shelved (branch
`shelf/drop-learning`); this part stays.

## Decision

- The saved list holds up to 1,000 terms of up to 50 characters
  (`VocabularyCache.maxTermCount`, `maxTermLength`).
- Each request takes, in list order, what its provider accepts
  (`VocabularyBudget.terms`): Deepgram about 450 estimated tokens, ElevenLabs
  Scribe Live 50 terms of up to 20 characters, Soniox about 7,000 tokens of
  context, the OpenAI Realtime prompt about 800 tokens, ElevenLabs recorded
  keyterms as before, and query terms within 8 KB of percent-encoded URL.
  Tokens are estimated as UTF-8 bytes / 3. A term that does not fit is left
  out of that request only.
- `VocabularyCache` posts a change notification on every write and an open
  Vocab editor reloads, so a list changed elsewhere (settings sync) is not
  overwritten by a stale copy.

## Why

- A global 50 x 20 cap wasted every provider with a larger limit.
- Lists saved since PR #406 may already hold more than 50 terms or longer
  terms. Going back to the old caps would send them whole to every provider
  and could break a realtime session (Deepgram fails mid-stream over its
  keyterm budget).

## What we tested

ElevenLabs Realtime sends 50 short terms in list order; Deepgram stops at its
token budget with Cyrillic counted conservatively; the other routes;
`accepts` and the realtime transport per account; the saved list accepts more
than 50 and longer terms (`VocabularyBudgetTests`).

## Rejected

- Reverting to 50 x 20 together with Drop learning: changes manual Vocab and
  can break sessions for lists saved since PR #406.

2026-11-23 · ORCH-TASK 72 REV 25 · shelve Drop learning PR
