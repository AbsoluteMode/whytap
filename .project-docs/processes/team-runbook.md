---
id: whytap-team-runbook
type: process
title: Whytap team runbook for the maintainer's coding sessions
summary: Scope and mandatory reading for sessions working in AbsoluteMode/whytap worktrees on the maintainer's Mac and for the build-queue builder, with the shared-app rules that used to open AGENTS.md.
status: confirmed
tags: [team, agents, worktrees, builder, queue, shared-app, guidance]
canonical_for: [team-session-scope, team-guidance-entry]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer agreed to rework the documentation for people who receive the repository; the task asked for a short AGENTS.md for outside users and contributors and a separate, explicitly scoped runbook for the team process, losing no rule.
    confirmed_at: 2026-11-22
  - type: repository
    reference: .project-docs/agent-context.md
    confirmed_at: 2026-11-22
  - type: repository
    reference: scripts/build-queue-builder-prompt.md
    confirmed_at: 2026-11-22
related: [../project.md, shared-app-development.md, local-customization.md, ../decisions/2026-11-22-short-agents-entry.md, ../decisions/2026-11-28-owner-preview-first.md]
---

# Whytap team runbook

## Scope

This runbook applies to:

- coding sessions working in a worktree or checkout of `AbsoluteMode/whytap`
  on the maintainer's Mac (the primary checkout `whytap`, its `exodia` alias,
  `.claude/worktrees/*` and any other worktree sharing its Git common
  directory);
- the build-queue builder and any session acting as integrator;
- any other agent the maintainer explicitly tells to follow it.

It does not apply to anyone else. Someone who cloned or forked Whytap, or
received the repository from a colleague, follows `AGENTS.md` and
`docs/architecture.md` only. The permissions recorded here (automatic
restarts of the installed app, routine integration without repeated approval,
messages between the maintainer's sessions, disk cleanup) were given by the
maintainer for this team and this Mac; they authorize nothing elsewhere.

## Read before any work, in full

1. This runbook.
2. [Parallel development, one working Whytap](shared-app-development.md):
   feature sessions, the build queue, the builder and the integrator gates.
3. [`docs/architecture.md`](../../docs/architecture.md): architecture,
   commands, documentation rules and invariants. Until 2026-11-22 it was the
   body of `AGENTS.md`; every rule in it still binds team sessions.
4. The primary checkout's local build receipt (build/CURRENT_BUILD.md) for
   what actually runs.

Before integration, packaging, launch or installation, fetch `origin` and read
these files from `origin/main` (`git show origin/main:<path>`); an older
worktree's copy may be stale.

## Branches older than this split

On 2026-11-22 the long `AGENTS.md` body moved, unchanged, to
`docs/architecture.md` (everything from the product paragraph and
Architecture to Invariants) and to this runbook (the checkout paragraph and
"Parallel development"). A branch made before that which edits the old
`.project-docs/agent-context.md` must move its edit, with the same words, to
the same paragraph in the new file, keep agent-context as the short
entry and regenerate `AGENTS.md`/`CLAUDE.md`. The builder does this when it
resolves such a conflict.

## Checkout

The canonical primary checkout folder is named `whytap`; an older `exodia`
path can remain a compatibility symlink for existing chats and worktrees.
It is not the project name. Older checkouts can contain unmerged source and WIP.
Consult current `origin/main` guidance and the primary build receipt before
treating an older checkout's naming or feature descriptions as the current app.

## Parallel development and the shared application

Read `.project-docs/processes/shared-app-development.md` for every feature task
and before integrating or updating the user's app. The user approved parallel
feature sessions with regular checked integration and one working application.

- Each feature uses its own branch/worktree. Workers build/test without
  launching, registering or installing their bundles. Do not run `dev-run.sh`
  or `customize.py build/run` from feature sessions; even build-only dev
  packaging on some branches stops other dev processes.
- Keep `/Applications/Whytap.app` (`com.rootwise.sidekey`) as the user's one
  working app, preserving signing identity, permissions and data. Source for
  shared updates is checked `origin/main`; first reconcile any fixes already
  installed from a feature branch. Do not replace them with older main code.
- Run exactly one Whytap instance across all channels: beta shares meetings,
  staging and clipboard history with production and competes for hotkeys.
  Production app/DMG packaging is reserved for the integrator under the lock.
- Finished feature agents automatically submit their reviewed PR/exact head,
  checks, dependencies and acceptance steps to the persistent build queue
  (`scripts/build-queue.py`; installed helper in the Git common directory).
  `enqueue` rejects a head whose guidance sync or documentation validation
  fails. The configured builder processes FIFO, sends queue/start/result
  messages to the originating sessions and alone integrates/packages/promotes;
  it resolves routine merge conflicts itself and blocks a PR once, listing
  every finding; a re-block is only for a problem the fix introduced or a
  listed item still unfixed. It is an on-demand headless
  session that a model-free launchd watcher (`scripts/build-queue-watcher.py`)
  starts only while the queue has open work, the screen is unlocked and the
  load is below its limit; only the maintainer activates or deactivates it.
  A model-free watchdog appends stalls, environment waits and unreachable
  authors to an alerts file. WHY:
  .project-docs/decisions/2026-11-23-builder-queue-watchdog.md These queue messages are user-authorized. Workers follow the
  result and report issues without starting competing builds. Follow the
  runbook for CLI inboxes, pending installs, their automatic retry and
  recovery. WHY: .project-docs/decisions/2026-11-19-on-demand-build-queue-builder.md
- The builder holds the shared `exodia-integration.lock` in
  `git rev-parse --git-common-dir` for protected operations. Queue claims never
  replace that lock or any validation gate. Preserve all other sessions' WIP;
  use a clean integration worktree when the primary checkout is occupied.
- Owner preview first (2026-11-28): the builder installs an app-changing PR
  as an unmerged preview with only the minimal safety checks (signature and
  identity, newer build number, no activity in progress, rollback bundle
  kept). Deep review, race probes and the full suite wait for the owner's OK,
  which the orchestrator records in `whytap-owner-decisions.txt`; after it
  only data loss, security and privacy findings block the merge, the rest are
  follow-ups. WHY: .project-docs/decisions/2026-11-28-owner-preview-first.md
- Review overlaps, validate the final combined candidate and merge through a
  PR with exact head/base checks. Routine checked integration/local refresh
  needs no repeated approval. Public publishing remains a separate action.
- After a PR merges, verify that GitHub removed its remote feature branch.
  Follow the shared workflow for branches GitHub leaves and for retired work.
- Build a production candidate without interrupting the installed app. Verify
  its signature/identity against the installed app and require a newer build
  number without downgrading the display version. Keep the last working
  bundle. The user authorized automatic normal restarts outside meetings on
  2026-10-20, accepting interruption of other work. Check the current meeting
  gate from the shared procedure; active/suspected meetings or an unknown
  result defer silently without repeated saved/idle questions. Never force-quit.
- Maintain build/CURRENT_BUILD.md in the primary checkout with separate
  ready, merged, pending and verified-running states, source SHA, included
  features and 1–3 acceptance steps. Report what actually runs and what to
  check after promotion. A merge alone does not update the running app.
- Bound developer backups: after a successful promotion retain one previous
  signed working app, remove obsolete app copies under the builder lock, and
  create full data snapshots only for actual migrations. Remove obsolete data
  reserves after migration preservation/recovery checks pass. Preserve every
  coding session, its work and unfinished rollback; follow the shared process's
  retention section. User-controlled Automatic backup is a separate setting.
- Before integration/app actions, fetch and reread current `origin/main`'s
  guidance even in older worktrees. Resolve technical overlaps from accepted
  requirements; report incompatible product choices or unresolved risks.

WHY: .project-docs/decisions/2026-10-19-shared-working-app.md
