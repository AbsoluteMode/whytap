---
id: case-remove-whytap-agent-2026-11-20
type: decision
title: Remove Whytap Agent from Case and retire built-in agent Case integration
summary: Case Connect offers only installed Claude Code and Cursor; Whytap's built-in agent no longer lists or runs Case secrets, while legacy builtInOpenCode vault entries remain safely decodable on disk.
status: confirmed
tags: [case, secrets, agents, connect, compatibility]
canonical_for: [case-connect-catalog]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user requested removing Whytap Agent from Case so Case connects only external coding tools (Claude Code and Cursor) while preserving existing Case vaults and keys.
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/Case/Clients/CaseClientSetup.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/Case/CaseViewModel.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/Case/Broker/CaseCallerResolver.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentTools.swift
    confirmed_at: 2026-11-20
related: [2026-10-21-case-connect-claude-code.md, 2026-10-22-native-agent.md]
---

# Remove Whytap Agent from Case

## Context

Case offered `Whytap Agent` (`.builtInOpenCode`) in **Case -> Connect** alongside
installed Claude Code and Cursor, gave the native Whytap Agent a `case_list_keys`
tool, injected `case mcp` into legacy OpenCode runs, and tracked child PIDs in
`CaseBuiltInAgentProcesses` so the Case broker matched them against a
`.builtInOpenCode` registration. The user decided on 2026-11-20 to remove Whytap
Agent from Case so Case serves external coding tools (Claude Code and Cursor)
only.

## Decision

- **Connect catalog:** `CaseKnownClient` removes `.builtInOpenCode`, and
  `CaseKnownClient.connectableClients` is `[.claudeCode, .cursor]`. When neither
  is installed and unregistered, `IslandCaseClientPicker` shows
  `"Install Claude Code or Cursor, then open Connect again."`
- **Built-in agent tools and runtime:** Remove `case_list_keys` from
  `NativeAgentTools`, `NativeAgentProvider.systemPrompt`, tool labels and
  `NativeAgentDiagnostics.Tool`. Remove `caseMCPCommand` from `AgentRunOptions`,
  `AgentSettingsStore`, `OpenCodeEnvironment` and `OpenCodeProvider`, and remove
  `CaseBuiltInAgentAccess` and `CaseBuiltInAgentProcesses`. Keep
  `BundledWhytapHelper.url` intact for non-Case helper uses (`screen-mcp` and
  `whytap todo` / `whytap app` `PATH` lookup).
- **Broker refusal:** `CaseCallerResolver` never matches `.builtInOpenCode`
  registrations, and `CaseSystemCallerResolver` passes the running Whytap PID
  (`hostPID`) so any helper call whose parent chain reaches Whytap itself
  resolves as `.knownUnregisteredAI(name: "Whytap Agent")` and is denied with
  `.unknownAIApp` instead of falling through to human Touch ID.
- **Legacy vault and rollback safety:** Keep `case builtInOpenCode` on
  `CaseAppIdentity` so existing schema-3 vaults, encrypted backups and rollbacks
  decode without error or data loss. `CaseViewModel` and
  `IslandCaseConnectedApps` hide retired `.builtInOpenCode` entries and refuse
  new registrations or access edits for that identity.

## Alternatives

- Remove `case builtInOpenCode` from `CaseAppIdentity`: rejected because an
  existing on-disk schema-3 vault or backup containing `"builtInOpenCode"` would
  fail `Codable` decoding and lock the user out of their keys, or break rollback
  if rewritten into a new schema.
- Drop `builtInOpenCodePIDs` from `CaseCallerResolver` without checking
  `hostPID`: rejected because a child command started by `NativeAgentCommand`
  running `whytap case run` would walk past `Whytap.app` to `launchd` and resolve
  as `.human`, triggering a misleading Touch ID prompt instead of refusing an
  unregistered AI caller.

## Rationale

Separating the built-in desktop assistant from Case narrows the Connect picker
and removes unused secret-discovery plumbing from every native Agent turn, while
keeping the on-disk schema-3 format compatible with existing vaults, backups and
the retained rollback bundle.

## Consequences

- **Case -> Connect** offers only installed Claude Code and Cursor; legacy Codex
  and custom-path registrations remain editable as before.
- Existing vaults that previously connected Whytap Agent unlock normally with
  all projects and secret values intact, without showing a connected Whytap
  Agent icon or granting Case access to Whytap-spawned commands.
- External `whytap case mcp`, `case ls` and `case run` behavior for Claude Code,
  Cursor and terminal users is unchanged.

## Supersedes / superseded by

Amends the Connect catalog in
[Case Connect offers Claude Code again](2026-10-21-case-connect-claude-code.md)
from `[.builtInOpenCode, .claudeCode, .cursor]` to `[.claudeCode, .cursor]`, and
supersedes the `case_list_keys` and child-PID Case registration clauses in
[Native Whytap agent](2026-10-22-native-agent.md).
