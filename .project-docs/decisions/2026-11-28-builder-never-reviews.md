---
id: builder-never-reviews-2026-11-28
type: decision
title: The builder never reviews code; one inquisition reviews the release candidate before it ships
summary: The Whytap builder builds, runs the tests and mechanical gates, merges, installs and rolls back; it never reviews code, runs race or interleaving probes or blocks on review findings, for previews, feature PRs or releases. An app-changing PR is installed as an unmerged preview for the owner first. Approved features accumulate on main; before a release the orchestrator has one release candidate built and fully tested, runs one inquisition (council review) on the whole release diff, gets its confirmed bugs fixed, and only then the release ships.
status: confirmed
tags: [agents, queue, builder, review, release, inquisition, preview]
canonical_for: [builder-review-scope, release-inquisition]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 (orchestrator card 42, spec REV 8) the owner said, translated - "Then when we assemble a release, the builder reviews one version well once. Actually no - remove the builder's ability to review anything at all. We'll just run an inquisition before the release. First we assemble everything, test, and then run just one inquisition and that's it. And fix its bugs."
    confirmed_at: 2026-11-28
  - type: user-confirmed
    reference: On 2026-11-28 (orchestrator card 42) the owner decided "rule now, code later" for the 2026-11-26 agreement that the owner checks a preview of a feature before tests and merge.
    confirmed_at: 2026-11-28
  - type: user-confirmed
    reference: On 2026-11-26 the owner set the order preview first, tests after approval, and no code review by the builder before that approval.
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/build-queue-builder-prompt.md
    confirmed_at: 2026-11-28
related: [../processes/shared-app-development.md, ../processes/team-runbook.md]
---

# The builder never reviews; one inquisition per release

## Context

The builder ran an independent deep review of every queued PR: reading the
diff and both features' contracts, race and interleaving probes on disposable
fixtures, "findings" with reproducing checks, and blocks with numbered lists
(rules from 2026-11-22 "builder blocks once" and 2026-11-23 "cheap fixes").
Each round took hours and mostly found hypothetical interleavings; PRs
cycled through block and resubmit, including the PRs that introduce the
owner's preview (#499, #501). On 2026-11-28 the owner removed the builder's
review entirely and moved review to one council pass on the assembled
release.

## Decision

- **The builder never reviews code**, for previews, feature PRs and releases
  alike. It does not read a diff to judge it, run race or interleaving probes,
  write review findings, ask for reproducing checks, or block on anything but
  a failing mechanical check. It does not invoke review agents.
- **What the builder still does** (gates, not reviews): build; documentation
  checks; `swift test --filter` of touched classes and the full suite; merge
  conflict resolution that keeps both sides' tests passing; exact head and
  base checks; signature, Developer ID team, designated requirement, a
  higher build number, `--installation-check`; the meeting and activity
  gate; one rollback bundle; build provenance; install; rollback.
- **Blocking** is only: the build or a test fails because of the PR, a
  documentation check fails, a merge conflict needs the author's choice, or
  the PR head moved. All failing checks go into one numbered list once.
- **Owner preview first.** An app-changing PR is first composed on current
  `origin/main` with the other previews awaiting the owner, built as the local
  arm64 app and installed as an unmerged preview with only the mechanical
  gates; the ticket is set `blocked` with a note starting `PREVIEW AWAITING
  OWNER` (not a failure). The orchestrator records each owner decision in
  `whytap-owner-decisions.txt` in the Git common directory. After an `ok` and
  the author's resubmission (main merged in, or an empty commit), the builder
  runs the full suite and merges. A `reject` cancels the preview ticket and
  the next install leaves the PR out. Builder tooling and documentation-only
  PRs have nothing to preview: their own tests and documentation checks, then
  the merge.
- **One inquisition per release**, triggered by the orchestrator, never by
  the builder:
  1. Approved features accumulate on main.
  2. The orchestrator decides to release; the builder builds the release
     candidate from one main SHA and runs the full suite on it.
  3. The orchestrator runs one inquisition (its council review: Fable 5.2,
     Opus 5.5 or Gemini 4 Carbon for visual subjects, and Astra 6.2) on the
     whole release diff, from the previous release's commit to the candidate.
  4. Confirmed bugs are fixed as ordinary PRs through the queue (no builder
     review); a new candidate is built and tested. The inquisition is not
     repeated unless the orchestrator decides so.
  5. The release ships (`user-release.sh`, with its provenance and candidate
     validation gates).
- This replaces the builder's review in the queue (the "builder reviews"
  point of the owner's builder spec) and the general review before merge.
  The superseded rules: the review parts of
  `2026-11-22-builder-blocks-once.md` and `2026-11-23-builder-queue-cheap-fixes.md`
  (block once now applies to failing checks only), and the never-merged
  owner-preview-first draft (#534), folded in here without its post-approval
  review.

## Why

- The owner checks features in the working app; tests guard every merge; one
  careful review of everything that ships finds real problems once, instead
  of per-PR reviews that stall each PR for hours on hypothetical issues.
- A council of different models reviewing the whole release sees interactions
  between features that per-PR review could not, at one fixed point.
- Mechanical gates protect the owner's app and data without judgment, so they
  stay with the builder.

## What we tested

- Documentation checks only (documentation validator, guidance sync check).
  No code changes: the queue helper and watcher never invoked a review; the
  review lived in the builder prompt and the shared workflow.

## Rejected

- The builder reviewing the release candidate once: the owner first proposed
  it, then withdrew it in the same message in favor of the inquisition.
- Keeping review only for data loss, security and privacy after the owner's
  OK (#534): superseded by this decision before it merged.
- Running the inquisition per feature: the owner asked for one, on the
  assembled release.

2026-11-28 · orchestrator card 42, spec REV 8
