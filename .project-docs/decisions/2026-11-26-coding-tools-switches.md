---
id: coding-tools-switches-2026-11-26
type: decision
title: Coding tools in Integrations are always listed with one switch that connects the tool
summary: Settings → Integrations → Coding tools always lists Claude Code and Codex. One switch per tool replaces a separate Connect - on writes Whytap's MCP entry through the same client setup as Case → Connect and records Yes in the harness access store; off records No and leaves the entry. A tool not on the Mac is grey. It stays in Integrations, not in Features.
status: confirmed
tags: [settings, integrations, mcp, harness-access, claude-code, codex]
canonical_for: [coding-tools-switches]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 (ORCH-TASK 116) the maintainer kept Coding tools in Integrations, "like installing the MCP" (translated), and approved ("go ahead") the variant described here - always visible, a row per tool found on the Mac, one switch instead of Connect, Connected / Not connected, a missing tool grey, no feature in Features. Lil Bro, also in that request, was removed from the app the same day, so this change does not add rows to it.
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Settings/CodingToolsAccess.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/Settings/CodingToolsAccessTests.swift
    confirmed_at: 2026-11-26
related: [2026-11-20-harness-access.md, 2026-11-21-one-whytap-mcp-server.md, 2026-11-21-first-launch-onboarding.md, 2026-11-26-every-feature-in-features.md]
---

## Context

Coding tools in Integrations appeared only after a tool had asked Whytap for
access in the island, and only as that answer. Adding Whytap's MCP server to
Claude Code or Codex was elsewhere: Case → Connect or the onboarding's last
page. Someone looking for "connect Claude Code" in Settings found nothing
until the tool had already connected.

## Decision

- Coding tools is always shown and always lists Claude Code and Codex, in that
  order (`CodingToolsAccess.tools`, the identities of
  `CaseCallerResolver.knownAIApps`).
- One switch per tool. **On**: `CaseClientSetup.connect` (the `whytap`
  command and the canonical `whytap` MCP entry, as Case → Connect and the
  onboarding do); once the tool has a `whytap` entry, Yes is recorded in
  `HarnessAccessStore`, the same answer the island's question stores. An entry
  the person wrote is left as it is and counts. If no entry is there after
  setup, no Yes is recorded and the row says what failed.
- **Off** records No at once. The MCP entry stays: without a Yes the gate
  refuses the tool, exactly as after a No in the island, and turning it back
  on needs no rewrite.
- The row says Connected (entry and Yes), Not connected, Checking, Connecting,
  or "Not installed on this Mac" with a disabled switch. Presence is read
  without writing (`CaseClientSetup.presence`: the client's locator and its
  read-only `isConfigured`), off the main thread, when Integrations appears
  and when Whytap becomes active again.
- Without the app's access store (a build that has no broker) the switches
  are disabled and the row points to the installed app.
- Other apps with an answer (a live dictation client) keep their switch per
  answer below the two tools, as before.

## Why

- Connecting a coding tool is installing an integration, so it belongs in
  Integrations; one switch is both steps the person means by "connect".
- Recording Yes only after the entry exists keeps "Connected" true: a tool
  with access and no server would never reach Whytap.
- Leaving the entry on Off keeps one rule for refusing a tool (the gate) and
  never touches the person's client settings to take something away.

## What we tested

`CodingToolsAccessTests`: the two tools are the identities the gate matches;
On writes the entry and records the island's Yes; Off records No, writes
nothing and leaves the entry; a failed setup records no Yes and shows the
setup's message or a fallback; a person's own entry counts; a missing tool is
grey and cannot be switched; no store, no switch; Checking before the answer;
other apps' answers listed below; pictures of Integrations in both themes.

Not checked in a running app: Connect against the real `claude` and `codex`
CLIs from this switch (the same `CaseClientSetup.connect` the onboarding uses).

## Rejected

- A Coding tools feature in Features: the maintainer chose Integrations.
- Removing the MCP entry on Off: it would edit the person's client settings
  to do what the gate already does.
- Hiding a tool that is not installed: a grey row says what is missing.

2026-11-26 · ORCH-TASK 116 (Coding tools)
