---
id: case-connect-claude-code
type: decision
title: Case Connect offers Claude Code again
summary: The Connect catalog is OpenCode, Claude Code and Cursor; Codex stays a legacy registration only.
status: confirmed
tags: [case, secrets, agents, connect, claude-code]
canonical_for: [historical-case-connect-claude-code]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user decided to offer Claude Code in Case → Connect again so a new user can connect the Claude desktop app's Claude Code there, without adding Codex.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Case/Clients/CaseClientSetup.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Case/Clients/CaseClientConnector.swift
    confirmed_at: 2026-10-21
related: [2026-10-21-claude-desktop-binary-layout.md, 2026-11-20-case-remove-whytap-agent.md]
---

# Case Connect offers Claude Code again

## Context

PR #119 (Case Connect: OpenCode and Cursor logos with grouped rights) narrowed
`CaseKnownClient.connectableClients` to OpenCode and Cursor. Claude Code and
Codex remained only as legacy registrations that stay editable from their
icons. A new user with the Claude desktop app therefore had no way to connect
its Claude Code to Case, which the user also needs for the product video.

## Decision

The Connect catalog is `[.builtInOpenCode, .claudeCode, .cursor]`, in that
order. Claude Code appears only when `ClaudeBinaryLocator` finds the CLI and it
is not registered yet. Codex is not offered. Nothing else changes: the existing
connector runs `claude mcp add -s user case -- <helper> case mcp`, the broker
identity, the bundled `claude-code` brand mark and the orange highlight are
reused; no new asset is added. The empty picker now names all three clients.

## Rationale

Everything Claude Code needs at the broker and client boundary already exists
and is tested; only the catalog filter hid it. Returning it is a one-line,
reversible change that keeps every legacy registration and right unchanged.
Codex stays out because the user asked only for Claude Code.

## What was tested

- Discovery over all eight installed/absent combinations of OpenCode, Claude
  Code and Cursor with an installed Codex: only installed offered clients are
  returned, in catalog order, with no command run and no file written.
- The picker offers Claude Code when installed and unregistered, hides it when
  not installed or already registered, never offers Codex and changes no
  saved rights.
- Every Connect row resolves to a bundled brand mark with visible artwork at
  22 pt; picker renders at 310/390 pt include a Claude Code row.

No live app check: feature sessions must not launch the app.

## Desktop layout follow-up

The initial catalog change found that the locator did not recognize the
desktop app's newer `<version>/<hash>/claude.app` layout. The integrated
[locator follow-up](2026-10-21-claude-desktop-binary-layout.md) now accepts
both flat and hash-folder layouts, compares versions numerically and uses a
stable tie-break. Executable regular files and symlinked CLI installs count;
directories and other special files do not. The existing newer-legacy-CLI
preference and broker identity remain unchanged. Actual Connect/Touch ID/MCP
setup against the user's Claude configuration remains a separate acceptance
step; the builder does not change that configuration for smoke.

## Alternatives rejected

- Keep the narrowed catalog and show Claude Code only as a legacy
  registration: new users could not connect it at all.
- Return Codex as well: not requested.
- Ship a separate Claude Code picker logo: the bundled `claude-code` mark
  already renders in the picker.

## Supersedes / superseded by

Amends the Connect catalog of PR #119 and
[Case Connect and scope](../../docs/decisions/2026-10-20-case-connect-and-scope.md);
scope, modes and broker checks are unchanged. On 2026-11-20,
[Remove Whytap Agent from Case](2026-11-20-case-remove-whytap-agent.md) narrowed
the Connect catalog to `[.claudeCode, .cursor]`; Claude Code discovery, Desktop
layout handling and connector setup remain as recorded here.

Implementation references: [Case broker](../../docs/decisions/2026-10-19-case-secrets-broker.md), [design](../../docs/DESIGN.md) and [product spec](../../docs/SPEC.md).
