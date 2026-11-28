---
id: agent-harness-instructions-2026-11-28
type: decision
title: Whytap's instructions for Claude Code and Codex live in WHYTAP.md beside the user's memory
summary: The Agent's folder keeps a Whytap-owned WHYTAP.md, rewritten when its text changes, that says who is answering (the user's own CLI on their sign-in, not a Whytap API or SDK), where the answer appears, what the whytap tools are for and how the folder works. Claude Code gets it with --append-system-prompt-file, Codex as developer_instructions; the user's AGENTS.md is never written.
status: confirmed
tags: [agent, harness, claude-code, codex, instructions, memory]
canonical_for: [agent-harness-instructions]
verified_at: 2026-11-28
sources:
  - type: user-confirmed
    reference: On 2026-11-28 the owner, testing local build 1802, read the island agent's "Claude (Sonnet 5.5) inside Whytap, built on the Claude Agent SDK" as "it works through the API" and asked for a Whytap folder carrying the instructions the harness needs (orchestrator task 106, spec REV 5).
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/AgentHarnessInstructions.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/AgentHarnessInstructionsTests.swift
    confirmed_at: 2026-11-28
related: [2026-11-27-agent-harness-cli.md, 2026-11-27-agent-plain-text-cards.md]
---

# Whytap's instructions for Claude Code and Codex live in WHYTAP.md beside the user's memory

## Context

The Right Command Agent runs the user's own `claude -p` or `codex exec` in
`Application Support/whytap/agent`. Its only Whytap guidance was a
first-turn prompt preamble starting "You are Whytap — the user's
assistant", while AGENTS.md (aliased as CLAUDE.md) is the user's memory
and was empty on the owner's Mac. Asked "is this Claude Code answering?",
Claude described itself as an assistant inside Whytap built on the Claude
Agent SDK, which the owner read as Whytap using an API.

## Decision

- **Same folder.** The workspace stays `whytap/agent`. Claude Code files its
  sessions under the working directory's path, so a new folder would orphan
  the resumable sessions, `sessions.json` and the user's memory, and the
  whytap MCP state already reports this path as `agentWorkspace`.
- **A managed file beside the memory.** WHYTAP.md holds Whytap's
  instructions: who is answering (the user's own Claude Code or Codex on
  their sign-in and plan; Whytap has no servers, key, model, API or SDK of
  its own; the Agent SDK wording in Claude Code's own prompt only describes
  its non-interactive mode), where the answer appears (the ~320 pt island,
  answer conventions, cards, no approval prompt), what the `whytap` MCP tools
  are for, the memory rules, the 15-minute resume window, the earlier
  built-in agent's leftovers and the Monitor/customization contracts.
  Whytap rewrites it whenever the text differs (a symlink there is replaced,
  not followed) and never writes AGENTS.md.
- **Passed as system-level instructions on each request.** Claude Code:
  `--append-system-prompt-file` with the WHYTAP.md path, which adds to Claude
  Code's own prompt; CLAUDE.md (the memory alias) and the user's global
  instructions still load as usual. Codex: `-c developer_instructions=<text>`,
  which adds to Codex's prompt; AGENTS.md in the folder still loads. If the
  file cannot be written (folder missing or read-only), Claude Code gets the
  same text inline with `--append-system-prompt`, and a stale file is never
  passed.
- **The user prompt keeps only per-turn reminders.** The first-turn preamble
  and customization block left the prompt; language, answer format, actions
  and screen reminders stay on every turn.
- **Leftovers stay.** `.opencode-runtime/` and `native-conversation.json` are
  kept for a rollback to an older Whytap
  ([2026-11-27-agent-harness-cli.md](2026-11-27-agent-harness-cli.md)); the
  instructions tell the agent not to read, change or delete them.

## Why

- A system-level layer is where identity belongs: in the user prompt the
  model treated "You are Whytap" as a persona, and the memory file is the
  user's, so Whytap must not write its rules there.
- Both CLIs were checked in headless mode before choosing (Claude Code
  2.1.325, codex-cli 0.171.0, a folder with an AGENTS.md marker and a
  managed marker): `claude -p` loads CLAUDE.md through the symlink and the
  appended file; `codex exec` outside a Git repository loads the folder's
  AGENTS.md and `developer_instructions`. Neither loads WHYTAP.md on its
  own, so nothing is doubled.
- Codex has no flag that appends a file (`model_instructions_file` replaces
  Codex's own prompt), so it gets the text; the file still shows what it
  receives.

## What we tested

- Resumed sessions keep their first turn's instructions in both CLIs: a
  `--resume` with a changed appended file and a `codex exec resume` with
  changed `developer_instructions` both quoted the original marker. An app
  update therefore reaches the next fresh session, at most 15 minutes after
  the last request; sessions begun before it keep the old preamble.
- `AgentHarnessInstructionsTests`: first run with empty memory, an update
  replacing an older and user-edited WHYTAP.md while AGENTS.md stays byte
  for byte, no rewrite when unchanged, a symlinked WHYTAP.md, the flags for
  new and resumed Claude Code and Codex turns, a missing folder, a read-only
  folder and a stale file in it. `AgentControllerTests`: the prompt carries
  no identity preamble.
- Live, from a fresh folder made by AgentDaemonWorkingDirectory and this
  code (empty memory), asked in Russian. Claude Code, to "is this Claude Code
  answering me now?": yes, it is the user's Claude Code started by Whytap,
  model Claude Opus 5.5; to the follow-up "so through Whytap's API or the
  Agent SDK?": neither, Whytap has no API of its own and runs the installed
  Claude Code with `claude -p`, the same program as in Terminal. Codex: yes,
  the user's Codex started through Whytap; Whytap runs the installed Codex
  with `codex exec`, Codex talks to OpenAI under the user's account, and
  Whytap has no API or SDK for this. An earlier wording that only explained
  the SDK mention still produced "through the Claude Agent SDK, not Whytap's
  API", so the text now states that Whytap uses no SDK.
- Not tested: the installed app end to end.

## Rejected

- Writing Whytap's rules into AGENTS.md or an `@import` in it: the user's
  file would change under them, and a user edit could drop the rules.
- .claude/CLAUDE.md or a second auto-loaded file: Claude Code only, still
  user-prompt level, and Codex would need another mechanism.
- `--system-prompt` or Codex `model_instructions_file`: they replace the
  tools' own prompts, losing their tool and safety guidance.
- AGENTS.override.md: Codex would ignore the user's AGENTS.md.
- A new `whytap-harness` folder: loses resumable sessions and needs a memory
  migration for no gain over the same files in the existing folder.
- Deleting the earlier agent's files now: they are kept for rollback.
- Codex `developer_instructions` overrides one the user set in their own
  Codex config for these requests; accepted, since the island needs these
  instructions, and the user's AGENTS.md and global Codex instructions
  still apply.

2026-11-28 · branch feature/agent-harness-instructions
