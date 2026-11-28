# Whytap Agent

Tap **Right Command** to ask by text, hold it to ask by voice. The answer
appears in the island. The Agent runs on the coding tool you already use,
**Claude Code** or **Codex**, with your own sign-in, plan, MCP servers, hooks
and skills. Whytap starts it on your Mac for each request and shows its answer.

## Connect

1. Install Claude Code or Codex and sign in once in Terminal (`claude`, or
   `codex login`).
2. In **Settings → Keys & models → Models**, open **Harness** and choose
   Claude Code or Codex. Whytap checks that it is installed and signed in;
   a pick that fails the check changes nothing and says what to do. The row
   also sets the model and reasoning from the tool's own list, and Codex's
   **Fast mode** when the model offers it. No model chosen means the tool's
   own default.
3. In **Settings → Features → Agent**, turn on **Agent**. For spoken
   requests, choose a Speech model (Advanced → **Agent voice** gives the Agent
   its own).

If this Mac used the earlier built-in agent, Harness asks once to choose
Claude Code or Codex. Nothing connects by itself; your keys, routes and data
stay as they were.

## What it can do

**Allow file edits and commands** (Settings → Features → Agent, on by
default) is passed to the tool as its own permission settings. Whytap never
turns on a blanket bypass (`bypassPermissions`,
`--dangerously-bypass-approvals-and-sandbox`).

| Harness | On (default) | Off |
| --- | --- | --- |
| Claude Code | `auto` permission mode: Claude Code's classifier decides each action | Reading, searching (its own web search and fetch) and Whytap's tools only; file-writing and command tools are removed |
| Codex | `workspace-write` sandbox; its `auto_review` reviewer answers escalation requests | `read-only` sandbox, no approvals |

An action neither the tool nor its reviewer approves is refused, not asked:
the island has no approval prompt yet. Everything else follows your tool's
own settings, permissions and sandbox. Web search, if any, is your tool's own.

Each request also gets Whytap's own tools as an MCP server named `whytap`:
change Whytap's settings, island tools and hotkeys, add Vocab and Filler
words, To-do, and, after a one-time Yes, meeting notes.
[Which client can use what](customization/app-control.md#which-client-can-use-what).

## Answers and actions

Links, returned file or folder paths and a single command to run appear as
action cards with keyboard shortcuts to select, insert and open them, even
when the Agent writes them as ordinary text in its answer. Those shortcuts are changed on Settings → Features → Agent (and in
Hotkeys). Nothing opens or is inserted until you act. **Escape** closes
the answer.

## Agent, coding tools and Case are three different things

- **Whytap Agent** (this page): your Claude Code or Codex behind Right
  Command, started by Whytap for each request.
- **The Whytap MCP server** for coding tools you already use (Claude Code,
  Codex, Cursor) in your own sessions: it lets them read and change Whytap
  settings and To-do, and Claude Code and Codex, after a one-time Yes in
  Whytap, read meeting notes.
- **Case**: a local secrets vault. A registered client sees key names, never
  values, and `whytap case run` puts values only into the command it starts.
  In **Accept** mode the island asks you before each such command (the
  approval shown in the README demo); **Bypass** does not. That approval
  covers only commands that use Case secrets through `whytap case run`, not
  the Agent's other actions.

## Memory

The agent's folder is `~/Library/Application Support/whytap/agent` (the
Whytap plugin's `whytap_get_state` names it as `agentWorkspace`, so Claude Code
or Codex can open it for you). Your tool starts each request there:

- `AGENTS.md` is long-term memory that you or the agent can edit; `CLAUDE.md`
  in the same folder is an alias to it, so both tools read the same file.
  Whytap never writes it.
- `WHYTAP.md` holds Whytap's own instructions for the tool: that it is your
  Claude Code or Codex on your sign-in (Whytap has no API or model of its
  own), how answers appear in the island and what the Whytap tools are for.
  Whytap replaces it when it updates, so put your own notes in `AGENTS.md`.
  Each request passes it to the tool as system instructions; a session that
  began before an update keeps the earlier instructions until a new one
  starts.
- A follow-up within 15 minutes resumes the tool's own session, so it keeps
  its context; after that a new session starts.

What the agent sends and where: [Privacy](privacy.md).
