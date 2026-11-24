---
id: drop-learning-shelved-2026-11-23
type: decision
title: Drop learning is shelved on a branch; what stays in the app is inert data handling only
summary: Learning from edits after Drop was taken out of the app (PR #428) and kept on branch shelf/drop-learning. The app no longer watches fields, shows suggestions or applies learned Replace rules. It still accepts the saved Replace rules key in backups so older archives restore, still ends the hidden calibration journal 14 days after calibration was switched on, and keeps the change notification that lets the island and Toolbox Filler editors see each other's edits.
status: confirmed
tags: [drop, backup, privacy, filler]
canonical_for: [drop-learning-shelved]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: ORCH-TASK 72, REV 25 forwarded by the orchestrator. The user said the feature is "too raw ... put it in a box for now" and, asked whether to switch it off by default, "no, for now we can just move it into some branch" (translated).
    confirmed_at: 2026-11-23
  - type: trace
    reference: Builder review of PR #428 head b0016e95 (queue ticket 475), findings on backup compatibility, calibration retention and Filler editor parity.
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Backup/ShelvedDropLearningData.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Tests/SidekeyTests/Backup/ShelvedDropLearningDataTests.swift
    confirmed_at: 2026-11-23
related: [2026-11-23-vocabulary-route-budget.md, 2026-11-24-agent-step-drops.md]
---

## Context

Learning Vocab, Replace and Filler suggestions from the user's edits after
Drop shipped in PRs #406, #409, #416, #417, #418 and #420. In live testing it
was too raw, and the user decided to take it out of the app for now rather
than switch it off. Its code, with unfinished fixes, is on the pushed branch
`shelf/drop-learning`.

## Decision

- PR #428 reverts those six PRs. Nothing watches a field after Drop, no
  suggestion drops show, Control-Y / Control-N are not registered, there is
  no "Learn from my edits" switch, and saved Replace rules are not applied.
- Kept as inert data handling (`ShelvedDropLearningData`):
  - `sidekey.drop.replacements.v1` stays in the Vocabulary backup section,
    so an archive or settings history entry written while the feature was on
    still validates and restores. The value is restored and never read.
  - The hidden calibration journal still ends on the shelved code's rule:
    calibration switched off with a clock set, or 14 days after it was
    switched on, deletes the journal file and the calibration keys. It runs
    at launch and hourly and reads nothing.
- Kept for the manual editors: `FillerTermsStore` posts a change notification
  on every write and each Filler editor model reloads, so the island and
  Toolbox editors see each other's edits. Vocab keeps the same, see
  [route budget](2026-11-23-vocabulary-route-budget.md).
- Other `sidekey.dropLearning.*` keys (switch, ledger of salted hashes,
  reason counters) stay untouched and unread.
- The Settings, Other group keeps the name "Drop" (it was "Recording" until
  2026-11-22).

To bring the feature back: revert the squash commit of PR #428 on a branch
from main, then merge `origin/shelf/drop-learning`. That revert also removes
the pieces above, which the restored code replaces.

## Why

- Rejecting an unknown key fails the whole settings restore, so dropping the
  key from the registry would make an older archive lose every setting.
- The journal holds edited words and was promised to delete itself after 14
  days; removing the code must not make it permanent.
- The Filler notification predates nothing else but serves manual editing
  too: without it the second open editor kept a stale list and its next save
  could bring a removed term back.

## What we tested

An older archive with Replace rules and manual Vocab restores through the
real staging and apply path; the journal stays 13 days and goes on day 14
with its keys, goes at once when calibration was switched off, gets a clock
without being written when there was none, and nothing changes when
calibration was never on; a manual add and remove in one Filler editor show
in the other. Full suite and documentation validation.

## Rejected

- Switching the feature off by default instead of removing it: the user
  asked for a branch.
- Deleting all `sidekey.dropLearning.*` keys: not needed, and it would lose
  earlier answers when the feature comes back.
- Deleting the journal at once on update: the user did not ask for it; the
  14-day promise is kept instead.

2026-11-23 · ORCH-TASK 72 REV 25 · PR #428
