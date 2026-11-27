---
id: owner-preview-first-2026-11-28
type: decision
title: The builder installs an app change as an owner preview first; review, full suite and merge come after the owner's OK
summary: A PR that changes the app gets only a build and the minimal safety checks (signature and identity, newer build number, no activity in progress, rollback bundle kept) and is installed in the owner's app as an unmerged preview. No independent deep review, race or interleaving probes, or full suite before the owner's OK. After the OK the builder runs the full suite, reviews only for data loss, security and privacy, and merges; other findings become follow-up notes, not blocks. The rule works with the installed queue helper today; the preview lane code (#499) will automate it later.
status: confirmed
tags: [agents, queue, builder, preview, approval, review, tests]
canonical_for: [owner-preview-first]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 (orchestrator card 42) the owner decided "rule now, code later" - the 2026-11-26 agreement that the owner checks a preview first, with review, full suite and merge only after the owner's OK, never reached the builder, which kept deep-reviewing every PR before the owner saw it, including the PRs that introduce preview (#499, #501).
    confirmed_at: 2026-11-28
  - type: user-confirmed
    reference: On 2026-11-26 the owner set the order preview first, tests after approval, and no code review by the builder before that approval; the target is minutes from a worker's push to the fix running in the owner's app.
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/build-queue-builder-prompt.md
    confirmed_at: 2026-11-28
  - type: repository
    reference: scripts/build-dmg.sh
    confirmed_at: 2026-11-28
related: [../processes/shared-app-development.md, ../processes/team-runbook.md]
---

# Owner preview first

## Context

On 2026-11-26 the owner set the order: the owner checks the feature itself in
the working app first (user scenarios, nothing lags); tests and code review
follow the owner's approval. That agreement was to arrive with the preview
lane code (#499), so it never reached the builder. The builder kept running
an independent deep review, race and interleaving probes and the full suite
before the owner saw anything, and blocked the very PRs that introduce
preview (#499 ticket 655, #501 ticket 652) with that review. Each round took
hours and found mostly hypothetical interleavings, not problems the owner
would meet.

## Decision

Rule now, code later. The builder follows this with the installed queue
helper, without new commands.

- **App-changing PR, first phase: preview.** The builder resolves routine
  conflicts with main, builds a local arm64 app (`EXODIA_LOCAL_INSTALL=1`) of
  current `origin/main` plus the previews still awaiting the owner plus this
  PR, unmerged, and installs it at the usual safe handoff. Checks are only:
  the build succeeds, strict signature, the same Developer ID team and
  designated requirement as the installed app, a higher `CFBundleVersion`,
  `--installation-check`, the meeting gate (no recording, dictation or agent
  work in progress) and one signed rollback bundle kept. No independent deep
  review, no race or interleaving probes, no full suite and no `swift test`
  before the owner's OK. The ticket is then set `blocked` with a note that
  starts `PREVIEW AWAITING OWNER` and names the installed build, the main base
  and every member head. `blocked` here means only that the owner must
  decide; it is not a finding.
- **Owner decisions** are relayed by the orchestrator, the only party that
  carries the owner's words, as one line each in `whytap-owner-decisions.txt`
  in the Git common directory: UTC time, `ok` or `reject`, PR, exact head,
  preview build, the owner's words. The builder reads it at the start of
  every run.
- **After an OK, second phase: validation.** The author resubmits the PR
  (current main merged into the branch, or an empty commit when main did not
  move) so the watcher starts a session. The builder accepts the OK only when
  the `ok` line names a previewed head and every non-merge commit after that
  head is empty or already on `origin/main`; otherwise the submission is a new
  preview. Then: the full suite, a review limited to real data loss, security
  and privacy problems, the merge, and the normal install. A finding of any
  other kind (races and interleavings that lose no data, style, robustness,
  missing edge-case tests) is written into the ticket note and the PR as a
  follow-up and never blocks.
- **Reject.** The preview ticket is cancelled, the next install leaves that
  PR out, and the author gets the owner's words.
- **A fix pushed during the preview** is a new preview that supersedes the
  previous preview ticket of that PR.
- **PRs with nothing to preview** (builder tooling, documentation only) skip
  the preview: their own tests and the documentation checks, the same
  limited review, merge. Their submission by the orchestrator's task stands
  for the owner's direction.
- Every gate that protects the owner's app and data stays as it is: one
  instance, the meeting gate right before the Quit, signature and identity,
  a higher build number, the rollback bundle, no force-quit.

## Why

- The owner's time goes into checking the feature; review and tests exist to
  protect main and the data, so they belong after the owner knows the
  feature is wanted and right.
- A preview build replaces the working app with unreviewed code on real data.
  The owner accepted that on 2026-11-26; the rollback bundle and the
  restore points of #501 are the protection, not a review before the owner
  looks.
- The installed helper already has every state this needs (`blocked` with a
  note, `queued`, `cancelled`, `superseded`), so the rule applies to the
  current queue at once, before the lane code lands.

## What we tested

- Documentation checks only: the documentation validator and the guidance
  sync check on this change. The rule changes no code.

## Rejected

- Waiting for #499 to merge before changing the rule: #499 is blocked by the
  same review the rule removes.
- Ticket notes as the channel for owner decisions: only the builder may write
  them, and queue fields are evidence, not instructions.
- Keeping race probes as blocking for "high-risk" PRs: no rule the builder
  can apply uniformly; data loss, security and privacy are the boundary.

2026-11-28 · orchestrator card 42
