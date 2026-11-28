---
id: local-fast-builds-batch-inquisition-2026-11-28
type: decision
title: Fixes are built locally into the owner's app at once; accepted fixes go through one inquisition and one batch build by the builder
summary: No build queue and no builder per fix. A finished fix is merged into one owner-local combined build (current main plus every fix still waiting for the owner) and installed into /Applications/Whytap.app with scripts/owner-local.py, behind the same signing, build-number, rollback and activity gates. The owner tests it. When many accepted fixes have accumulated, the orchestrator runs one inquisition over the batch and the findings are fixed; only then the builder builds the batch (merge and release build), without review.
status: confirmed
tags: [agents, builder, queue, local-build, install, inquisition, process]
canonical_for: [fix-delivery, owner-local-build]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 (orchestrator card 42, spec REV 10) the owner said, for the third time, translated - "we are dropping the builder for every fix ... Put it in the project status: you and I build everything locally, fast. I check, test and see that the functionality is what I intended. Only after that we run the inquisition. When many fixes have accumulated we run the inquisition, fix the findings and hand it to the builder just to build all of it."
    confirmed_at: 2026-11-28
  - type: repository
    reference: scripts/owner-local.py
    confirmed_at: 2026-11-28
related: [../processes/shared-app-development.md, ../processes/team-runbook.md]
---

# Local fast builds, one batch inquisition, builder only for the batch

## Context

Every fix went through the persistent build queue: FIFO behind other PRs, a
builder session, checks, often a full suite, then an install. Fixes the owner
was waiting to try took hours to reach the app, and the owner had to restate
the intended process three times by 2026-11-28. The preview-through-the-builder
variants (the manual `PREVIEW AWAITING OWNER` rule of
`2026-11-28-builder-never-reviews.md` and the preview lane of
`2026-11-26-preview-before-validation.md`) still put each fix in the queue.

## Decision

1. **No builder and no build queue per fix.** Workers do not `enqueue` fixes;
   the builder processes no per-fix tickets.
2. **Each fix is built locally and fast and installed into the owner's app**
   with one command, `python3 scripts/owner-local.py add <PR> --accept
   "<PR>=<1-3 steps>"`. It keeps one combined build = current `origin/main` +
   every fix still waiting for the owner (state in `whytap-owner-local.json` in
   the Git common directory, dedicated worktree `worktree` inside the `.whytap-owner-local` folder of the user's home),
   so installing fix B never drops fix A. Under the shared
   `exodia-integration.lock` it merges the members, builds the signed local
   arm64 app (`EXODIA_LOCAL_INSTALL=1 ./scripts/build-dmg.sh`, same identity
   and bundle id, build number above the installed one, native
   `--installation-check`), keeps a rollback copy, runs the meeting and Whytap
   activity gate right before a normal Quit (never a force-quit; a busy app
   defers and the candidate stays for `owner-local.py install`), swaps the
   bundle, relaunches it and records the contents and acceptance steps in
   the build receipt in the primary checkout.
3. **The owner tests** and confirms the functionality is what was intended.
   A rejected fix is removed with `owner-local.py drop <PR>`; a fix of a fix
   is `add <PR>` again with the new head.
4. **One inquisition per batch.** When many accepted fixes have accumulated,
   the orchestrator runs one inquisition (council review) over the batch and
   the confirmed findings are fixed (and checked by the owner the same local
   way).
5. **The builder only builds the batch**: merge and release build, behind its
   mechanical gates and tests, never a review
   (`2026-11-28-builder-never-reviews.md`).

## Why

- The owner judges features in the running app; minutes, not hours, from a
  fix to that check is the point.
- One combined local build is the smallest mechanism that keeps every
  waiting fix in the app at once; the existing local install mode, activity
  gate and lock already hold the safety rules.
- Review and the builder's full validation are spent once, on what the owner
  accepted, instead of on every intermediate fix.

## What we tested

- `scripts/owner-local.py` was used to deliver PR #539 and PR #538 on top of
  the previously installed fixes (see the PR that adds this record).
- Documentation validator and guidance sync on this change.

## Rejected

- The per-fix build queue (FIFO, builder session per fix): hours per fix.
- Builder-installed previews (manual `PREVIEW AWAITING OWNER` tickets, the
  preview lane with `approve`/`reject`): still a queue and a builder per fix.
- Each worker building and installing only its own branch: installing fix B
  would drop fix A from the owner's app.

2026-11-28 · orchestrator card 42, spec REV 10
