---
id: whytap-app-control-plugin
type: decision
title: Local agent plugin for application state, models and settings
summary: Expose allowlisted live app controls over the existing authenticated helper transport, with optimistic concurrency and no direct preferences-file editing.
status: confirmed
tags: [agents, plugin, mcp, settings, models, local]
canonical_for: [app-control-plugin]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user requested a Whytap plugin and selected state, models and settings, including changing the Smart model, as its first version.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/AppControl/AppControlController.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/WhytapCaseKit/AppControlMCPServer.swift
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user requested easier access to Whytap Case through the CLI or the existing plugin.
    confirmed_at: 2026-10-21
  - type: repository
    reference: plugins/whytap/mcp.json
    confirmed_at: 2026-10-21
related: [../processes/local-customization.md, 2026-10-22-agent-answers-and-screen.md, 2026-11-03-todo-helper.md]
---

## Context

Source customization discovery and show-only application links already exist.
Neither lets an external agent read or change the running routing store. A
Smart model change therefore required native UI interaction. Editing defaults
outside the process would leave the app's in-memory routing state stale.

## Alternatives

- Continue native UI automation: works but depends on the visible UI and input routing.
- Add setting writes to `whytap://`: unsafe for arbitrary website invocations and provides no response.
- Add an independent HTTP service: duplicates local transport and creates another exposure boundary.
- Extend the bundled helper's private transport with a separate allowlisted namespace.

## Decision and rationale

Use `whytap app` and a local stdio MCP plugin. Reuse only Case's authenticated
transport, not its vault, registration, grants or secret operations. The
controller exposes four non-secret settings and model/provider selection.
Model selection uses the existing Settings checker and preserves unrelated
routes. A changed model drops the old model's provider pin. Reads return live
metadata, not transcripts, keys or raw defaults. Status/settings reads do not
initialize Keychain-backed model discovery.

Every mutation requires the exact current value. Async model checks also
recheck the route and cancellation before committing. This prevents a slow
probe from replacing a newer manual choice. Only one plugin mutation runs at
a time. Connection loss around a synchronous commit requires a read before
retrying; it cannot guarantee rollback of an already completed change.
MCP cancellation notifications and EOF close the pending request's socket;
the app's existing disconnect watcher cancels its task. The stdio reader
stays responsive while tools run, with a limit of 16 pending calls.

The plugin also bundles the existing names-only Case MCP as a second server.
This makes one plugin installation expose both interfaces while keeping their
authorization paths separate. Case uses its existing registrations, project
scope and approvals; installing the plugin grants no access. Secret use remains
in `whytap case run` through the agent's own terminal. Neither MCP server gains
a value-read or command-execution tool.

## Sources

The user selected the first-version scope on 2026-10-21. The implementation
and disposable-store/probe tests are in the referenced source paths and
`Tests/SidekeyTests/AppControl/`, `Tests/WhytapCaseKitTests/AppControlMCPServerTests.swift`.

## Comments and objections

Case's transport authenticates the bundled helper; it does not establish
human intent for a settings command. Any local process running that helper
as the user can invoke these controls. Keep the allowlist explicit; security,
credential, recording and user-content access require their own design.

## Resolution

The first version implements the selected scope and documents its local
access boundary. Plugin host installation and the actual running app remain
separate acceptance steps after source validation and queued integration.

## Consequences

Agents can change Smart's model through the app and verify the resulting
route without input automation. The installed helper and app must be from
the same build. Provider validation can run a tiny paid synthetic probe,
as it does in Settings. Public directory distribution is not part of this change.

## Supersedes / superseded by

No prior decision is superseded. Show-only links and source customization
remain separate interfaces.
