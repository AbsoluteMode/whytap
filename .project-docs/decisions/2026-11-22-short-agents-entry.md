---
id: short-agents-entry-2026-11-22
type: decision
title: AGENTS.md is a short entry; architecture and the team process have their own files
summary: AGENTS.md/CLAUDE.md shrink to a short entry for outside users and contributors that sends team sessions to a scoped runbook first; the former body moves unchanged to docs/architecture.md and the team runbook.
status: confirmed
tags: [guidance, agents, documentation, team, onboarding]
canonical_for: [agents-md-structure]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 Maxim checked what a new user's agent says when handed the Whytap repository; it recommended the app but was confused by contradicting documents and by the maintainer's recorded permissions. He agreed to rework the documentation, including a short AGENTS.md and a separately scoped team runbook.
    confirmed_at: 2026-11-22
  - type: repository
    reference: scripts/build-queue-builder-prompt.md
    confirmed_at: 2026-11-22
  - type: repository
    reference: scripts/build-queue.py
    confirmed_at: 2026-11-22
related: [../processes/team-runbook.md, ../processes/shared-app-development.md]
---

## Context

`AGENTS.md` and `CLAUDE.md` (generated from `.project-docs/agent-context.md`) were 148 KB:
the maintainer's shared-app process, the full architecture and many recorded
permissions ("the user authorized automatic restarts"). An outside user's
agent read them as instructions for itself and could not tell the product
from the team's workflow. The team's sessions and the on-demand builder,
however, rely on reading `AGENTS.md` first.

## Decision

- `.project-docs/agent-context.md` (and so `AGENTS.md`, `CLAUDE.md`) is a short entry: a
  first block that sends any session in an `AbsoluteMode/whytap` worktree on
  the maintainer's Mac, the builder and integrators to
  `.project-docs/processes/team-runbook.md` in full before any work; then what
  Whytap is, that recorded permissions are not the reader's, how to build and
  test, where documents live and the rules for changes.
- `docs/architecture.md` holds the former Architecture through Invariants
  sections and the product/name paragraph, unchanged except the Documentation
  section's pointers to itself.
- `.project-docs/processes/team-runbook.md` holds the scope, the mandatory
  reading list (runbook, shared-app process, architecture, build receipt) and
  the former checkout and "Parallel development" text unchanged.
- The builder prompt and the shared-app process name all three files.

## Why

An outside agent needs a page it can act on; team sessions need every rule.
Putting the pointer in the first lines of the file both groups already read
keeps old sessions and the installed builder prompt (which reads
git show origin/main:AGENTS.md) on the full rules without a reinstall.
Moving text instead of rewriting it guarantees nothing is lost.

## What was tested

- Every non-empty line of the old `.project-docs/agent-context.md` appears in
  `docs/architecture.md` or the runbook, except the four lines of the
  Documentation section that pointed to `CLAUDE.md` as "this file".
- `sync_agent_guidance.py --check`, `validate_project_documentation.py
  --tracked-documentation`, `tools/customization` and `scripts/test-build-queue.py`
  pass; `build-queue.py` only checks that the three guidance files are
  byte-identical, so a shorter file does not affect `enqueue`.

## Rejected

- Keeping the long file and adding an outside-user preface: the permissions
  and team rules would still read as instructions.
- One runbook with architecture inside: contributors outside the team need
  the architecture and invariants too.
- Rewriting the architecture text while moving it: risk of losing rules.

2026-11-22, this PR.
