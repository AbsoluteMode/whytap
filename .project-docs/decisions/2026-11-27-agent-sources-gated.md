---
id: agent-sources-gated-2026-11-27
type: decision
title: Connected Agent sources stay in the code but are gated off until the owner decides
summary: The connected-sources feature from PR #491 (MCP servers, GitHub, Jira, folders for the Right Command Agent) is hidden behind one code constant, AgentSourcesGate.isEnabled = false, with no user-visible toggle. With it off there is no Settings entry, no source tool or context for the Agent, no MCP server process, no scan of other apps' configurations, no gh call and no manifest or Keychain access. The code and its tests stay; tests enable the feature per instance. User-facing docs no longer describe it.
status: stale
tags: [agent, native-agent, sources, mcp, feature-gate, privacy]
canonical_for: [agent-sources-gate]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: "On 2026-11-27, after #491 had merged and shipped in Whytap 2.2.27 (1784), the owner said the feature is better not shown while it is unclear whether it will stay; the orchestrator decided to hide it behind an off-by-default gate rather than revert it."
    confirmed_at: 2026-11-27
  - type: commit
    reference: 6bc1cd8a2cf73736c77492a800309246f552092f:Sources/Sidekey/Assistant/Connections/AgentSourcesGate.swift
    confirmed_at: 2026-11-27
  - type: commit
    reference: 6bc1cd8a2cf73736c77492a800309246f552092f:Tests/SidekeyTests/Assistant/AgentSourcesGateTests.swift
    confirmed_at: 2026-11-27
related: [2026-11-26-agent-sources.md, 2026-11-27-agent-harness-cli.md]
---

# Connected Agent sources are gated off

Historical decision: superseded on 2026-11-27 by [the agent harness](2026-11-27-agent-harness-cli.md): connected Sources were removed with the built-in agent.

## Context

PR #491 (iteration 1 of `docs/plans/2026-11-26-assistant.md`, see
`2026-11-26-agent-sources.md`) merged as `a9de60ac` and shipped in Whytap
2.2.27 (1784). The owner then moved the Assistant to the backlog and asked
not to expose the feature while it is unclear whether it will stay.

## Decision

One constant, `AgentSourcesGate.isEnabled`, ships `false`. There is no
user-visible toggle. While it is off:

- Settings → Features → Agent mounts no Sources section and no Add source…
  (`AgentFeatureSettings.showsSources`). Help, settings search and the hover
  catalog never mentioned the feature.
- `AppDelegate` does not install the Agent's source catalog, and the
  Agent's default `NativeAgentSources.offered()` returns nothing even if one
  were installed: no `source_call` tool and no source text in the prompt.
- `SourcesController` (its `isEnabled` comes from the gate) does not read or
  write `sources.json`, register its sleep observer, touch Keychain at all
  (every read, write, delete and presence check goes through one accessor
  that is nil while off), resolve or start server commands, connect, or serve
  `callRead`; `agentCatalog()` is nil.
- `MCPConfigImporter.scan()` reads no Claude Code, Claude Desktop, Cursor,
  Codex or VS Code configuration; `GitHubCLISignIn.token()` does not run `gh`.

All code and its tests stay. Tests construct controllers and importers with
`enabled: true`; `AgentSourcesGateTests` covers the shipped state.

User-facing docs (`docs/agent.md`, `docs/privacy.md`, `docs/SPEC.md`) no
longer describe the feature. Developer docs (`docs/architecture.md`,
`docs/customization/README.md`, `2026-11-26-agent-sources.md`) note the
gate. To turn the feature on, set the constant to `true`, update
`testTheFeatureShipsGatedOff`, and restore the user-facing text from
`a9de60ac` (the `## Sources` section and the `source_call` row in
`docs/agent.md`, the "Agent sources" row in `docs/privacy.md`, the "Agent
sources (2026-11-26)" section in `docs/SPEC.md`).

## Why

Hiding keeps the reviewed work (the MCP client, the credential policy and
redaction, the taint rule and their regression tests) buildable and tested,
so resuming costs one line instead of a re-review of a revert. Guards sit
both at the entry points and inside the controller, importer and `gh`
sign-in, so a future caller that forgets the gate still starts nothing.

On the owner's Mac no source had been added when the gate was written (no
`integration.*` Keychain items), so no user data is orphaned. Any
`sources.json` or `integration.*` Keychain item someone created with 2.2.27
stays untouched and is used again if the gate is turned on.

## What we tested

`AgentSourcesGateTests`:

- The shipped gate is off, and so are the shared controller, the default
  importer and the Settings flag.
- With the gate off, adding a command or folder source returns nil and
  creates no directory or manifest, writes nothing to Keychain, never
  resolves the command and never starts the launcher, which would leave a
  marker file.
- A manifest written by an enabled controller is not read, is left
  byte-identical, and its server is never started; `check`, `setEnabled`,
  `setSecret` and `callRead` do nothing or refuse.
- The importer finds candidates and problems in populated configuration
  files with the gate on (control) and returns an empty scan with it off.
- `GitHubCLISignIn.token()` returns nil.
- Every Keychain path of an off controller (single and bulk presence,
  the secret mask, writes, deletes, connects) never reaches the store; an
  existing item stays unchanged and is not reported present (builder
  reproducer `testBuilder700DisabledControllerNeverQueriesSourceCredentialPresence`).
- A `NativeAgentProvider` built with the production default, while a
  catalog is installed, never consults that catalog and sends no
  `source_call` and no source text to the model (control: the request
  carries its other tools, and `offered(enabled: true)` returns the
  catalog).
- Source checks: the Settings mount and the AppDelegate wiring sit inside
  the gate's branch, and no other app file reaches the feature's entry
  points.

The existing source suites still pass with the feature enabled per
instance.

## Rejected

- Reverting #491: it would lose reviewed work and its tests, and resuming
  would need a fresh review.
- A hidden user default or a Settings toggle: the owner asked not to expose
  the feature, and a default can be flipped outside code review.
- Gating only the Settings mount: the Agent catalog, the importer and the
  controller would still be reachable from code.

2026-11-27 · gate PR follows #491 (`a9de60ac`).
