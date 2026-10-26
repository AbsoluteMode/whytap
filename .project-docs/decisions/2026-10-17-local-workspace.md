---
id: local-workspace-2026-10-17
type: decision
title: Local workspace, direct launch and coding-harness customization
summary: Keep user knowledge on the Mac, configure features in Settings and make source customization discoverable to local agents.
status: confirmed
tags: [local, projects, knowledge, onboarding, customization, byok]
canonical_for: [local-workspace, direct-launch, project-knowledge-foundation]
verified_at: 2026-10-17
sources:
  - type: user-confirmed
    reference: User requests in the 2026-10-17 Whytap task for local configuration and project knowledge, coding-harness customization and removal of onboarding.
    confirmed_at: 2026-10-17
  - type: repository
    reference: Sources/Sidekey/AppDelegate.swift
    confirmed_at: 2026-10-17
  - type: commit
    reference: 2cc4caa786e4a36052ae940929ffbc518d52e33f (Sources/Sidekey/Knowledge/ProjectKnowledgeStore.swift, historical implementation)
    confirmed_at: 2026-10-17
  - type: repository
    reference: scripts/customize.py
    confirmed_at: 2026-10-17
related: [2026-10-26-first-launch-permissions.md, 2026-10-19-remove-projects.md, ../project.md, 2026-09-10-onboarding-models.md]
---

# Local workspace and direct launch

The project-library portion of this decision is superseded by
[removal of Projects](2026-10-19-remove-projects.md). Direct launch and source
customization remain current.

## Context

The user wants an open-source macOS application with local configuration and
knowledge, provider API keys, and no Whytap account or paid plans. Project code
and documents must support questions such as which values a database field may
accept. The user also asked to remove onboarding and make the app easy for a
coding harness to customize.

## Alternatives

Keep the old resumable tour; require a hosted knowledge service; or give each
harness separate setup instructions. These add an entry gate, a service
dependency or duplicated guidance to the requested local workflow.

## Decision

Launch straight to the island and configure providers, permissions and agents in
Settings. Remove the onboarding screens, router, resume state, preview target
and demo resources. Preserve explicit permission repair and feature-triggered
macOS permission requests.

Add a local project catalog, manual notes and bounded SQLite FTS5 indexing of
explicitly selected folders. Retrieve cited excerpts for the selected project;
do not infer an exhaustive database constraint from a few observed values.

Provide a harness-neutral source map, executable customization helpers and
hover/dashboard drafts. Shared `AGENTS.md` and `CLAUDE.md` remain generated from
one canonical source. Custom collectors publish passive snapshots outside Git.

## Rationale

This follows the user's chosen workflow: open the app immediately, configure
their own providers, keep knowledge locally, and ask a familiar coding agent to
make a focused change with native validation.

## Sources

The dated user requests and implementation files in the frontmatter.

## Comments and objections

No objections to direct launch or a local source customization workflow were
recorded. The user requires agents performing review to be able to run tests.

## Resolution

Settings is the configuration entry point. The source checkout is the current
customization interface; app self-modification and a universal plugin engine
are not part of this implementation.

## Consequences

Project indexing is lexical and manually refreshed, bounded to 5,000 files or
32 MB of selected text. Hidden files, symbolic links, build directories and
common credential filenames are excluded. These exclusions are not a claim
that arbitrary project files contain no sensitive information.

Local storage does not make remote inference offline: chosen excerpts and notes
may be sent to the user's selected model provider. The project library is a
foundation for Meeting Assistant; live call-question detection and a validated
long-duration copilot are not implemented by this change.

## Supersedes / superseded by

Supersedes the first-run flow in [provider setup in onboarding](2026-09-10-onboarding-models.md).
The earlier record remains as historical rationale.
