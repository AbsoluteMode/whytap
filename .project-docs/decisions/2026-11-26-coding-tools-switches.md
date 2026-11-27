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
  onboarding do); once the tool has Whytap's own `whytap` entry, Yes is
  recorded in `HarnessAccessStore`, the same answer the island's question
  stores. An answer given while setup runs (a No in the island) is newer and
  stays.
- **Only Whytap's own entry counts.** The client's `whytap` entry is compared
  with what Connect writes for this app's helper
  (`CaseClientConnector.whytapEntry`: none, ours, custom). Any other entry,
  working or not (another path or build, other arguments, env, a URL, `null`,
  `{}`, Codex's `enabled = false`, a file that cannot be read), is the
  person's: the row says so, the switch stays off and cannot be turned on,
  no Yes is recorded and the entry is left as it is
  (2026-11-21-one-whytap-mcp-server). The person can remove it to connect
  here or answer Yes when the tool asks in the island.
- **No helper, no new Yes.** Without a `whytap` helper that runs in this app,
  no entry is Whytap's working one (a blank command or one naming a helper
  that is gone is just an entry), setup refuses and On records nothing; an
  earlier Yes can still be turned off.
- **Off** records No at once. The MCP entry stays: without a Yes the gate
  refuses the tool, exactly as after a No in the island, and turning it back
  on needs no rewrite.
- The switch shows the gate's answer: a Yes can always be turned off, also
  for a tool Whytap no longer finds or whose entry is gone, and the line says
  what is missing. Otherwise the row says Connected (entry and Yes), Not
  connected, Checking, Connecting, or "Not installed on this Mac" with a
  disabled switch. Presence is read without writing (`CaseClientSetup.presence`:
  the client's locator and its read-only `whytapEntry`), off the main thread,
  when Integrations appears and when Whytap becomes active again; a read that
  started before a newer one was applied is dropped. Each refresh re-reads the
  answer that applies (a Yes whose seal is gone no longer shows), and the row
  follows every change of the store, a late save included.
- Without the app's access store (a build that has no broker) the switches
  are disabled and the row points to the installed app.
- Other apps with an answer (a live dictation client) keep their switch per
  answer below the two tools, as before.

## Why

- Connecting a coding tool is installing an integration, so it belongs in
  Integrations; one switch is both steps the person means by "connect".
- Recording Yes only after the entry exists keeps "Connected" true: a tool
  with access and no server would never reach Whytap.
- Whytap does not judge someone else's entry. Tickets 671, 672 and 673 each
  came back with a new shape of a person's entry that the tool cannot start
  but Whytap counted (blank commands, bad URLs and ports, `null` fields, env
  and headers that are not strings). Re-implementing Claude Code's and Codex's
  config schemas is a race Whytap cannot finish; comparing with the one entry
  Whytap writes is exact and needs no update when the tools change.
- The gate honours a Yes whatever the local checks find, so the switch must
  follow the gate: a Yes the person cannot see or take back is worse than a
  row that says the server is missing.
- Leaving the entry on Off keeps one rule for refusing a tool (the gate) and
  never touches the person's client settings to take something away.

## What we tested

`CodingToolsAccessTests`: the two tools are the identities the gate matches;
On writes the entry and records the island's Yes; Off records No, writes
nothing and leaves the entry; a failed setup records no Yes and shows the
setup's message or a fallback; a person's own entry counts; a missing tool is
grey and cannot be switched; no store, no switch; Checking before the answer;
other apps' answers listed below; pictures of Integrations in both themes.

The builder's review of ticket 671 found five classes of faults (a Yes not
revocable without the tool or entry, an On overwriting a newer No, unusable
entries counted as connected, a stale answer after the seal went or a late
save, an old presence read replacing a newer one). `CodingToolsRegressionTests`
holds the builder's seven reproducers and one for the new row lines. Tickets
672 and 673 found more entry shapes counted as connected; instead of a schema
per tool, `CodingToolsEntryTests` checks that only Whytap's own entry is ours
for Claude Code, Codex and Cursor, that every shape the builder reported is
custom, that On then records no Yes, writes nothing and leaves the file as it
was, and that a Yes given with a custom entry can be taken back. Ticket 676
found a Yes recorded with the helper missing (a blank command matched the
missing path, an entry named a helper that was gone);
`CodingToolsHelperAvailabilityTests` holds the builder's fixture for both
tools and Off for an earlier Yes.

Not checked in a running app: Connect against the real `claude` and `codex`
CLIs from this switch (the same `CaseClientSetup.connect` the onboarding uses).

## Rejected

- A Coding tools feature in Features: the maintainer chose Integrations.
- Removing the MCP entry on Off: it would edit the person's client settings
  to do what the gate already does.
- Hiding a tool that is not installed: a grey row says what is missing.
- Checking each transport the way Claude Code and Codex read their configs
  (tickets 672–673): a copy of two schemas that keep changing, and every
  missed field a false Connected.
- Replacing a custom entry on On: Whytap leaves the person's entry as it is
  (2026-11-21-one-whytap-mcp-server).

2026-11-26 · ORCH-TASK 116 (Coding tools)
