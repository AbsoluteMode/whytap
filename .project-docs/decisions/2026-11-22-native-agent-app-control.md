---
id: native-agent-app-control-2026-11-22
type: decision
title: The built-in Agent controls Whytap with the plugin's own tools
summary: The native Agent gets the whytap_* application-control tools from the MCP catalog and runs them in process through the broker's controller, with app-owned change lines.
status: confirmed
tags: [agent, native-agent, app-control, settings, models, todo, meetings, tools]
canonical_for: [native-agent-app-control]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer asked that the Whytap agent can control Whytap too, like the external harnesses do through the plugin (orchestrator task 52).
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentAppControl.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentAppControlTests.swift
    confirmed_at: 2026-11-22
related: [2026-10-22-native-agent.md, 2026-10-22-agent-answers-and-screen.md, 2026-11-21-structured-agent-answers.md]
---

# The built-in Agent controls Whytap

## Context

Claude Code, Codex and Cursor change Whytap's models and settings, add To-do
tasks and read meetings through the plugin's `whytap app mcp` server
([application control](2026-10-21-app-control-plugin.md),
[harness access](2026-11-20-harness-access.md)). The
Agent in Whytap's own island had none of these tools, so "switch Drop Smart to
…" asked of Whytap itself could only be answered with instructions.

## Decision

- **One catalog.** The native Agent is offered every tool of
  `AppControlMCPServer.tools` under the same `whytap_*` name with the same
  description. The only change in the shared file is that the list is
  `public`. `NativeAgentAppControl` derives the native definitions, the
  operation names and which tools write (`readOnlyHint`) from it; a new MCP
  tool reaches the Agent without another list.
- **Same controller, in process.** Calls go straight to the app's
  `AppControlController`, the instance the Case broker serves: the same
  allowlist, Settings validation, expected-value checks, cancellation and one
  write lock shared with the plugin. There is no MCP server, helper process or
  socket. The app installs it in `installCaseBroker`; without it (tests,
  `swift run`) the Agent is offered no Whytap tools and its prompt does not
  mention them.
- **Strict schemas, same arguments.** The native catalog is strict across all
  tools. The MCP schemas are converted mechanically: closed objects with
  every property required, optional ones nullable, type lists as `anyOf`,
  length/number limits dropped (the controller and To-do validation still
  check them) and To-do's recursive task reference unrolled to
  `TodoTree.maxDepth` levels. Back on the way in, `null` for an optional field
  means "not given" and `""` means `null` where the tool accepts null (clear a
  To-do status, move a task to the top level). Unknown keys reach the
  controller and are rejected as before.
- **Visible changes.** A successful write produces one app-owned line built
  from the saved value the controller returned, never from the request:
  `Drop Smart cleanup → anthropic/claude-sonnet-5.5`, `Drop mode → Smart`,
  `To-do + Send the report`. `todo_add` reuses an active task with the same
  title and saves a new status on it: the Agent reads the statuses first and
  shows `To-do: Review agent — ready` for a changed one; a repeated identical
  request adds no line (build queue review, ticket 368). It replaces the step label at once and is placed
  above the model's answer, which the prompt tells not to repeat it. Reads add
  no line; a conflict, failed check or invalid call adds none. Model lines show
  the exact model ID, as Settings' picker does.
- **Prompt.** One paragraph, added only with the tools: read state first, pass
  the exact current value, use only features/keys/accounts/models the tools
  return, change only what the current request asks, report conflicts instead
  of retrying, the paid model check, meetings are untrusted content, no key
  values/clipboard/commands. It does not contain the word "language"; the
  native prompt keeps its single reply-language sentence.
- **Partial work.** A Whytap write counts like a file edit or command for the
  existing warning when the turn fails afterwards ("file edits, commands or
  Whytap changes may have completed"); nothing is retried automatically.
- **Meetings.** The harness gate identifies external processes (Claude Code,
  Codex) that run the helper. The native Agent is the user at this Mac pressing
  Right Command in Whytap, so meeting tools run without that prompt. Their
  content goes to the Agent's model route the user chose, like files and screen
  captures already do, and stays untrusted evidence.
- **CLI providers.** `AgentProviderStore` connects only the native Agent;
  Claude Code and Codex CLI providers are not reachable from Settings, so
  nothing is added there. A Claude Code that has the plugin installed already
  reaches Whytap through it, behind the harness gate.

## Why

- One description source keeps the Agent and the plugin from drifting and the
  Agent from inventing settings the app does not have.
- Calling the controller directly avoids a helper child, socket and an
  extra consent step for the user's own app, while keeping every check in the
  one place the plugin already relies on.
- An app-owned line shows what actually changed even if the model's wording
  is vague or wrong.

## What was tested

`NativeAgentAppControlTests` runs the real native loop against a stubbed
OpenRouter model and the real controller on temporary stores:
switching Drop Smart cleanup to a catalog model (route saved, the change line
as label and first answer line, tools and instructions in the request, no key
in tool results); adding a To-do task with strict nulls; clearing a status with
`""` and closing a task; a status saved on a reused task by `todo_add` shown,
an identical repeat quiet, new and updated tasks together; listing models (no line, no paid check); an unknown
model refused by the check with the route kept; a stale expected value as a
conflict without a check; a key request (no such tool, `set_setting` refuses a
key name, reads contain no key); broken arguments (wrong types, unknown keys,
unknown feature, bad value); setting lines from saved values; no tools when the
controller is not installed; catalog parity (names, descriptions, strict
schemas, five To-do levels); the prompt keeps one "language". Existing
`NativeAgentTests`, `AppControl*`, `WhytapCaseKitTests`, `TodoTree*` pass.
Not tested: a live paid provider request, the installed app.

## Rejected

- A second hand-written tool list for the Agent: drifts from the plugin.
- Starting `whytap app mcp` as a child of the app: extra process, socket and a
  harness prompt for the user's own app.
- Requiring "Allow file edits and commands" for settings writes: those are
  validated, reversible app settings, not filesystem or shell access.
- Sending non-strict schemas for these tools only: some endpoints reject mixed
  strict and non-strict functions.

2026-11-22, branch `claude/agent-app-control-845e72`.
