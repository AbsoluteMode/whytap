# Whytap Agent

Tap **Right Command** to ask by text, hold it to ask by voice. The answer
appears in the island. The agent is built into Whytap: tools and memory stay
on your Mac, and inference runs at the provider you choose, with your key.

## Connect

1. In **Settings → API & Models → API keys**, add an OpenRouter, OpenAI or
   Anthropic key.
2. Under **Models**, choose the **Agent** model (and **Agent voice** for spoken
   requests).
3. In **Settings → Other → Agent**, turn on **Agent**.

Turning it on connects: it prepares the local workspace and checks that a key and a model are
present; it does not prove that the provider accepts the key. Requests are
billed by your provider. Whytap never switches to another provider or model on
its own.

## Answers and actions

Links and returned file or folder paths appear as action cards with keyboard
shortcuts to select, insert and open them, even when the model returns them as
ordinary text. Nothing opens or is inserted until you act. **Escape** closes
the answer.

## Web search

Add a **Tavily** key in **Settings → API & Models → API keys**. Saving checks
the key without running a search. Only the search query goes to Tavily (at
most two searches per request); the returned excerpts and links go to your
selected model. Without a key, search reports an error instead of using
another service.

## Off by default; what it can do once on

The Agent is off until you turn on **Agent** in **Settings → Other**. Turning
it on keeps **Allow file edits and commands** (in the same place) at its
default, on, so from the first request the model you chose can use these
tools:

| Tool | With "Allow file edits and commands" on (default) | Off |
| --- | --- | --- |
| `list_directory`, `read_file`, `search_files` | yes | yes |
| `capture_screen` (when your request needs the screen) | yes | yes |
| `web_search` (Tavily key), `fetch_url` (public HTTPS) | yes | yes |
| `write_file`: create or replace a file | yes | removed and refused |
| `run_command`: run a shell command | yes | removed and refused |
| `case_list_keys`: Case key names, never values | only after you connect the Whytap agent in Case | same |
| `whytap`: change Whytap's own settings, island tools and hotkeys, To-do (next version after 2.2.26) | yes | yes |

Paths can be absolute or start with `~`; relative paths are inside the
agent's folder. Nothing confines the agent to that folder: it acts with your
macOS user's rights on any file you can read or write, and commands run as
you, with a 30-second limit and bounded output. **This is an action policy,
not a sandbox.** Turning the switch off removes writing and commands but
keeps reading files, searching, web access and screen capture. There is no
per-action approval yet; file contents, web pages and screenshots it reads
go to your model provider. Leave the switch off unless you want the Agent to
act on your Mac.

## Agent, coding tools and Case are three different things

- **Whytap Agent** (this page): Whytap's own model loop behind Right Command,
  with the tools above. It does not ask before a file edit or a command.
- **The Whytap MCP server** for coding tools you already use (Claude Code,
  Codex, Cursor): it lets them read and change Whytap settings and To-do,
  and Claude Code and Codex, after a one-time Yes in Whytap, read meeting
  notes. Your coding tool's
  own permission prompts and sandbox apply to everything else it does.
  [Which client can use what](customization/app-control.md#which-client-can-use-what).
- **Case**: a local secrets vault. A registered client sees key names, never
  values, and `whytap case run` puts values only into the command it starts.
  In **Accept** mode the island asks you before each such command (the
  approval shown in the README demo); **Bypass** does not. That approval
  covers only commands that use Case secrets through `whytap case run`, not
  the Agent's other actions.

## Memory

The agent's folder is `~/Library/Application Support/whytap/agent` (the
Whytap plugin's `whytap_get_state` names it as `agentWorkspace`, so Claude Code
or Codex can open it for you):

- `AGENTS.md` is long-term memory that you or the agent can edit.
- Recent text context resumes for 15 minutes, limited to six question/answer
  pairs and 12,000 characters, for the same provider, model and endpoint.
- Screenshots, tool output and reasoning are not written into that history.

What the agent sends and where: [Privacy](privacy.md).
