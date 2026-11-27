---
id: agent-harness-cli
type: decision
title: The Agent runs on the user's own Claude Code or Codex
summary: Right Command moves from the native in-app agent to the user's Claude Code or Codex CLI, with the model list from the CLI, real permission flags instead of a bypass, and the prompt kept out of argv.
status: confirmed
tags: [agent, claude-code, codex, permissions, settings, privacy]
canonical_for: [agent-harness, agent-permission-flags, claude-model-catalog]
verified_at: 2026-11-27
sources:
  - type: user-confirmed
    reference: On 2026-11-27 the maintainer approved ten decisions for task 106 (move Right Command to Claude Code or Codex) after a three-model council; this record lists them under Decision.
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/AgentHarnessFlags.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/ClaudeModelCatalogReader.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/CodexProvider.swift
    confirmed_at: 2026-11-27
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/AgentHarnessIntegrationTests.swift
    confirmed_at: 2026-11-27
related: [2026-10-22-native-agent.md, 2026-11-20-harness-access.md, 2026-11-21-one-whytap-mcp-server.md, 2026-11-27-subtitle-engine-choice.md, 2026-11-22-agent-provider-web-search.md, 2026-11-26-agent-sources.md, 2026-11-27-agent-sources-gated.md, 2026-11-24-agent-minimal-reasoning.md, 2026-11-23-agent-low-effort.md, 2026-11-26-agent-fast-search-answers.md, 2026-11-22-native-agent-app-control.md, 2026-11-20-agent-command-utf8-locale.md, ../project.md, 2026-10-19-api-hints.md, 2026-11-21-first-launch-onboarding.md, 2026-11-21-free-api-report.md, 2026-11-22-onboarding-journey.md, 2026-11-26-test-suite-speed.md, 2026-11-27-settings-models-recompute-while-hidden.md, 2026-11-27-compact-key-tiles.md]
---

# The Agent runs on the user's own Claude Code or Codex

## Context

Right Command ran Whytap's native agent: direct model HTTP with the user's
OpenRouter, OpenAI or Anthropic key, Whytap's own tool loop, Tavily or
provider web search and connected Sources. The Claude Code and Codex
providers from before the native agent were still compiled but unreachable,
and they had drifted: the Claude model was pinned to `sonnet` (and a saved
model was rewritten to it on launch), the Claude model list came from a scan
of the binary for `opus|sonnet|haiku`, both CLIs ran with a blanket
permission bypass described as a "testing phase", Codex received the
selected text and request as a command-line argument, and the idle watchdog
reported its timeout in Russian.

## Decision

The maintainer approved, on 2026-11-27:

1. Keys & models → Models shows Speech · LLM · Harness. Search (it existed
   for the native agent's web search) and the Agent's text model leave Models.
2. Harness expands inline with a disclosure chevron like the other Models
   rows, without a Configure button or a separate tab: Claude Code or Codex,
   model, reasoning, Fast mode (Codex, when the model has it) and status.
3. The model list comes from the CLI: Claude Code's `initialize` answer,
   Codex's `model/list`. No hard-coded model and no binary scan.
4. The native agent is deleted, not hidden: NativeAgent*, Tavily web search,
   connected Sources, per-turn cost, OpenCode leftovers, dead setup views,
   their settings, onboarding and help strings, and tests.
5. No blanket permission bypass; the Codex prompt goes through stdin; no raw
   stderr or content in logs; the watchdog message is English.
6. "Allow file edits and commands" keeps its stored value and maps to real
   permission flags of each CLI; Off must actually restrict.
7. The CLIs run with the user's own setup (MCP servers, hooks, skills), as
   in their terminal.
8. Existing native-agent users get a one-time "choose a harness" state;
   nothing connects by itself; keys, other routes and data stay.
9. Insert and the other answer cards, Whytap app control through MCP, Case,
   voice input, history and resume stay.
10. The change ships as a series of PRs through the build queue.

### Permission flags

| Allow file edits and commands | Claude Code | Codex (`exec` and `exec resume`) |
| --- | --- | --- |
| On (default, as before) | `--permission-mode auto --permission-prompts none` | `-c sandbox_mode="workspace-write" -c approval_policy="on-request" -c approvals_reviewer="auto_review"` |
| Off | `--permission-mode dontAsk --permission-prompts none --disallowedTools Bash,PowerShell,Monitor,Edit,Write,NotebookEdit --allowedTools Read,Grep,Glob,WebSearch,WebFetch,mcp__whytap` | `-c sandbox_mode="read-only" -c approval_policy="never"` |

On uses each harness's own reviewed autonomy: Claude Code's auto mode decides
each action with its classifier; Codex's `auto_review` reviewer answers
escalation requests from its workspace-write sandbox (the `--approve-for-me`
flag, which `exec resume` does not accept, is the same setting). Nothing is
left waiting for a person: the island has no approval bar, so an action the
policy does not approve is refused and the turn ends normally. If an account
has no auto mode, Claude Code refuses risky actions rather than running them.

Every turn also adds Whytap's own MCP server (the running app's
`Contents/Helpers/whytap mcp`) under the name `whytap`, the name
Integrations → Coding tools registers, through `--mcp-config` or
`-c mcp_servers.whytap.*`. It replaces that entry for the turn instead of
adding a second copy; the user's other servers still load. App control and
screen capture therefore work without the Coding tools switch, and the
existing per-harness Yes (2026-11-20 harness access) still gates them,
because the helper's parent is the signed CLI.

Turns run in Application Support/whytap/agent. If that folder cannot be
created, the turn fails instead of running in Whytap's current folder.

### Model and reasoning

Claude Code answers an `initialize` control request on its stream-json
stdin with `models[]` (`value`, `displayName`, `description`,
`supportsEffort`, `supportedEffortLevels`) and its version, without a model
request. Whytap stops the child as soon as the answer arrives and never
writes a user message. The answer also contains the account (e-mail,
organization); it is not decoded, shown or logged.

The saved model is sent verbatim as `--model`. With no pick, or with Claude
Code's own "Default" entry, no `--model` is sent and the CLI uses its own
default, as in the terminal. A saved model the catalog no longer lists stays
selected as "(saved)". Reasoning follows the selected model: the user's pick
when the model takes it, else Low when it takes Low, else no `--effort`.

### Privacy and robustness

- Codex reads the prompt from stdin (`-`), so selected text and requests
  never appear in argv, where any local process can read them.
- Provider logs carry exit codes and byte counts only, never stderr, paths,
  arguments or answers (`LocalPathLoggingInvariantTests`).
- A probe whose output is not the expected JSON fails with a fixed message;
  an exit code alone never reports a sign-in, and stderr is not shown.
- Codex item-level `error` events are notices (unknown config keys, hook
  timeouts, an unsupported service tier, an offline plugin marketplace) and
  no longer end the turn; top-level `error` and `turn.failed` still do.
- The final stdout chunk at exit is split into lines before parsing.
- A cancelled Claude turn's late result or exit can no longer close or clear
  the next turn's stdin. A result or exit that arrives while the child is
  still starting is kept and applied to that turn's own writer once it is
  registered (`TurnHandleBox`, locked). Publication of the writer and the
  exit's clear both run on the provider's serial session queue, and the exit
  is recorded first, so an exited writer never becomes the active one. A new
  turn takes ownership on entry, before the CLI lookup, the Agent folder or
  its child, and only the latest turn may publish or clear the active writer,
  so a replacement that cannot start (no CLI, no Agent folder), fails to
  start or exits early never leaves an earlier turn's writer active. When the
  latest turn ends, the provider drops its reference, so an idle provider
  retains no writer (`ClaudeTurnLifecycleTests`, from build-queue probe 721).
- Model discovery fails closed like a turn: without the Agent's folder in
  Application Support, Claude Code is not started at all (it would load that
  folder's settings and run SessionStart hooks), and Settings says so.
- The sign-in checks (`ProcessOneShot`) have one deadline for the whole call:
  a child that ignores TERM is killed and the check counts as failed, and a
  helper that inherited the pipes cannot hold the call open. Output on either
  pipe without EOF by the deadline also fails the check: a signed-in-looking
  prefix is never read as a whole answer.
- A saved Claude model missing from a loaded model list keeps its name but
  gets no `--effort`: nothing shows it accepts one.

## Why

- Users who already pay for Claude Code or Codex get their own sign-in,
  tools, MCP servers and memory on Right Command, without a second key, and
  Whytap stops maintaining a separate agent loop, web search and source
  connectors that their harness already has.
- A blanket bypass plus the user's whole MCP setup is a much larger blast
  radius than the native agent's two tools. Each harness's reviewed mode
  keeps "On" useful while Off is enforced by the CLI itself.
- Argv is readable by every local process; stdin is not.
- The binary scan could not see new model families (Fable) or what the
  account can use; the CLI's own list can.

## What we tested

Live, with Claude Code 2.1.325 and codex-cli 0.171.0 on the maintainer's Mac
(their own configuration, MCP servers and hooks):

- `initialize` returned 14 models in about 0.5 s after six SessionStart
  hooks; Haiku 4.5 has no reasoning levels, Opus 4.6 has no `xhigh`.
- Claude Off: Write and Bash are absent from the session, also for a Task
  subagent; Read, WebSearch and `mcp__whytap__whytap_todo_list` work.
- Claude On (`auto`): Write and Bash run.
- Codex Off: file creation and `touch` fail in the read-only sandbox; the
  Whytap MCP tool works. A resumed thread with Off also fails to write.
- Codex On: file creation and `touch` run.
- Per-turn Whytap MCP: one `whytap` server for Claude (21 tools, no
  duplicate of the user's entry) and for Codex.
- `AgentHarnessIntegrationTests` (opt-in) runs the same checks through
  `ClaudeCodeProvider` and `CodexProvider` in a temporary folder: Off blocks
  writes on new and resumed turns, On writes, Whytap tools answer.
- Codex with an unsupported model returns a top-level error and
  `turn.failed`, which still surface.

Not measured: answer latency against the native agent.

## Rejected

- Blanket bypass (`bypassPermissions`, `--dangerously-bypass-approvals-and-sandbox`): the owner rejected it.
- Claude `--restricted` for Off: it also ignores the user's settings files, against decision 7.
- An approval bar in the island now: a separate design; the parked `PermissionPrompt` code stays.
- Writing Whytap's MCP entry into the user's global CLI config: a turn-scoped flag changes nothing on disk.
- A hard-coded default model (Sonnet): the owner asked for the CLI's own list; no pick means the CLI's own default.
- A Harness tab or a Configure button: the owner chose an inline chevron row like the other Models rows.

## Implementation

1. Runtime hardening (this record's first PR): permission flags, stdin prompt,
   Claude catalog, per-model reasoning, Whytap MCP, logging, English messages.
   The native agent still runs Right Command until the next step.
2. Settings and dispatch (second PR): Models shows Speech · LLM · Harness
   (Search and the Agent route leave Models; the `.agent` route is inactive
   but stays stored). The Harness row expands in place: harness menu, model,
   reasoning, Codex Fast mode when the model has a fast tier, status line and
   "Check again". A pick becomes active only after its sign-in check passes.
   The choice is stored under `agent.harness.active`; the earlier
   `agent.activeProvider` is read only to show the one-time "choose a harness"
   ask (`agent.harness.chosen` stops it from returning) and is never written
   or removed, so a rollback build finds its native connection as it was.
   Right Command dispatches only to Claude Code or Codex; without a harness the
   island says "Choose a harness" and opens Models. The onboarding language
   model step uses the shared LLM row's features instead of the Agent route.
   Same PR, owner request: Subtitles engine choice
   (2026-11-27-subtitle-engine-choice.md).
3. Deletion (third PR): the built-in agent is gone, not hidden: its model
   loop, tools, finish_answer schema, plain-text card fallback, provider web
   search and Tavily (API keys tile, onboarding step, hints, backup entry,
   README card and its four images, the bundled mark), connected Sources and
   their settings, per-turn agent cost metering, the OpenCode leftovers
   (installer, config, built-in Case client in the picker), the dead
   Agents-tab setup views, the model-author artwork downloader and the
   catalog's web-search flag. Stored data is not touched: the Tavily Keychain
   item, `agent.native.*` and `agent.opencode.*` values, the `.agent` route,
   native-conversation.json, OpenCode runtime files and a saved built-in
   Case registration stay readable for a rollback build; Whytap no longer
   reads the Tavily key or backs it up. Answer cards come from the
   `useful.actions` fence the prompt asks for. The decisions that defined the
   removed behavior are marked stale with a pointer here; records that only
   mentioned Tavily carry a "superseded 2026-11-27" note.

2026-11-27 · task 106
