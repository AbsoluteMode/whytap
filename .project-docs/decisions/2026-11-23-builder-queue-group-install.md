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
- After merging a runtime PR the builder does not package when another
  runtime ticket can be claimed now, fewer than four merged runtime tickets
  already wait for an install, and none of them changes stored-data formats
  or migrations, permissions (TCC), Keychain items, signing or entitlements,
  or the updater. It records `pending_install --retry-install` with "install
  grouped", lists the PR under "Merged, not installed" in the build receipt
  and takes the next ticket.
- The watcher already takes queued work before a waiting install, so the
  group installs once the queue has no claimable ticket, through the same
  meeting gate. That session packages one candidate from current main and,
  after the verified install, closes every ticket of the group.
- A PR of the listed kinds is installed alone, and a waiting group is
  installed before such a PR is merged.

## Rationale

The install is the step whose cost does not depend on how many PRs it
contains, while tests and merges are where a culprit must stay obvious. A cap
of four keeps one rollback bundle meaningful. PRs whose effects a binary
rollback cannot undo stay in their own install. Reusing `--retry-install`
needs no new state, so the installed watcher handles a group before and after
`activate`.

## Alternatives

- Batch claim, batch tests and bisection: rejected by the council review.
- A new `merged_pending_install` status: duplicates `pending_install` and
  needs every helper and watcher to know it.
- No cap: one overnight install could carry fifteen PRs behind one rollback.

2026-11-23
