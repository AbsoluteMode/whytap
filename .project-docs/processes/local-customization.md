---
id: whytap-local-customization
type: process
title: Customize Whytap through a local coding harness
summary: Discover source capabilities, make focused edits, validate locally and inspect the native development app.
status: confirmed
tags: [customization, harness, codex, claude-code, opencode, swift, local]
canonical_for: [local-source-customization]
verified_at: 2026-10-17
sources:
  - type: repository
    reference: scripts/customize.py
    confirmed_at: 2026-10-17
  - type: repository
    reference: tools/customization/capabilities.json
    confirmed_at: 2026-10-17
  - type: repository
    reference: scripts/dev-run.sh
    confirmed_at: 2026-10-17
related: [shared-app-development.md, team-runbook.md, ../decisions/2026-10-21-app-control-plugin.md]
---

# Local source customization

Start a coding harness in the source checkout. Read `AGENTS.md`, then run
`python3 scripts/customize.py discover --json` and `doctor --json`. The tool map
points to the source and focused checks; it is shared by all harnesses.

The complete procedure is [Customize Whytap](../../docs/customization/README.md).
It includes hover integration, JSON dashboard contracts and local data boundaries.
`build` and `run` use the stable beta development bundle. Scaffold commands only
create drafts, and existing output directories are rejected.

For the maintainer's parallel sessions, follow
[the shared application procedure](shared-app-development.md) before these
helpers: feature workers use non-launching Swift builds/tests and the integrator
alone updates the installed production app. Even build-only dev packaging may
stop another development process.

Build and test locally. The helpers do not publish, release, replace the installed
production app or modify user stores. Keep the source capability map current when
renaming an entry point, and regenerate `AGENTS.md` and `CLAUDE.md` from
`.project-docs/agent-context.md` after changing shared guidance.
