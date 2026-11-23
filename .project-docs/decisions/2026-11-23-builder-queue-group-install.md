---
id: whytap-builder-queue-group-install-2026-11-23
type: decision
title: Runtime PRs are reviewed, tested and merged one at a time and installed in groups of up to four
summary: After merging a runtime PR the builder defers packaging while more runtime work is queued, up to four merged PRs; the watcher installs the group once the queue is empty through the usual meeting gate; PRs touching data formats, permissions, Keychain, signing or the updater install alone.
status: confirmed
tags: [agents, queue, builder, install]
canonical_for: [builder-group-install]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-23 the maintainer approved the reduced builder-queue order; its fourth step is to combine only the installation, keeping batch merges, a review stage and a fast lane out.
    confirmed_at: 2026-11-23
  - type: repository
    reference: scripts/build-queue-builder-prompt.md
    confirmed_at: 2026-11-23
related: [2026-11-19-on-demand-build-queue-builder.md, 2026-10-20-meeting-aware-builder-refresh.md, 2026-11-23-builder-queue-cheap-fixes.md, ../processes/shared-app-development.md]
---

# Group installs, single merges

## Context

Every runtime PR got its own signed production build and install: about five
minutes of packaging, signing and verification, plus a quit and relaunch of
the working app, even when the next runtime PR was already waiting. About 75
signed builds were made for 99 closed tickets in the measured days from 2026-11-20 to 2026-11-22.
The council review of the batch plan rejected batch merges and batch tests
(a failed batch does not reliably name its culprit, a partial merge leaves an
untested prefix in main) but recommended grouping only the install.

## Decision

- Review, tests and merge stay per PR, unchanged.
- At submission the helper marks a ticket `runtime` when any changed path,
  both sides of renames and deletions included, is outside documentation,
  tests, `.github/` and the queue's own scripts; unknown counts as runtime.
- After merging a runtime PR the builder does not package while the group of
  merged runtime tickets waiting for an automatic install, this one included,
  stays below four, another runtime ticket can be claimed, and none of them
  changes stored-data formats or migrations, permissions (TCC), Keychain
  items, signing or entitlements, or the updater. It records
  `pending_install --retry-install` with "install grouped", lists the PR under
  "Merged, not installed" in the build receipt and takes the next ticket.
- The install boundary is enforced by the helper and the watcher, not only by
  the prompt: four waiting automatic installs, or one marked `--install-first`
  (automatic, before other runtime work) or `--hold` (a person must act),
  make `claim` and the watcher skip runtime tickets, which keep their place,
  and put the install before queued work, also while the meeting gate is
  busy. Work that does not change the app still runs.
- A PR of the listed kinds installs alone: claimed while a group waits, it is
  returned to its place and the group is marked `--install-first`; merged but
  not installable now, it is `--hold` or `--install-first`.
- `pending_install -> pending_install` records a prepared candidate or changes
  the flag without leaving the group, so an interrupted install session finds
  the same group and candidate.

## Rationale

The install is the step whose cost does not depend on how many PRs it
contains, while tests and merges are where a culprit must stay obvious. A cap
of four keeps one rollback bundle meaningful. PRs whose effects a binary
rollback cannot undo stay in their own install. The boundary lives in the
queue's `retry` values and a `runtime` column, so no new status is needed;
older helpers and watchers ignore both, which is why grouping starts with
`activate`.

## Alternatives

- Batch claim, batch tests and bisection: rejected by the council review.
- A new `merged_pending_install` status: duplicates `pending_install` and
  needs every helper and watcher to know it.
- No cap: one overnight install could carry fifteen PRs behind one rollback.
- The boundary in the prompt only: the builder review showed a fifth PR or an
  isolated one passing it while the gate was busy or a person had to act.

2026-11-23
