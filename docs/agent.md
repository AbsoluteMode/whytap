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

When the Agent model is on **Anthropic**, **OpenAI** or **OpenRouter**, it
searches with that provider's own web search tool: no extra key, billed by
the same provider (at most two searches per request).

| Agent route | Search | Price (checked 2026-11-22) |
| --- | --- | --- |
| Anthropic | Claude web search (`web_search_20250305`) | $10 per 1,000 searches plus the results as input tokens; failed searches are not billed. Included in the Agent's estimated cost |
| OpenAI | Responses `web_search` | $10 per 1,000 calls plus search content tokens. OpenAI reports no charge, so the cost stays unknown |
| OpenRouter | `openrouter:web_search` | the model's own search at its provider's price, otherwise Exa at about $7 per 1,000; included in the cost OpenRouter reports |

The provider runs the search and sends its results to the model; Whytap
never sees a separate search request. The pages the model cites appear as
source cards. If the model lists none itself, Whytap shows the provider's
citations (up to five).

**Tavily** is the fallback. Add its key in **Settings → API & Models → API
keys** (saving checks the key without running a search). It is used when the
model has no web search of its own (the Anthropic catalog says so, a few old
OpenAI models such as `gpt-4.1-nano`, or the provider rejects the search tool
on the first request), or when **Search the web with Tavily** is on in
**Settings → Other → Agent**. Only the search query goes to Tavily; the
returned excerpts and links go to your selected model. With neither, the
Agent has no search tool and says it could not check the web instead of
inventing recent facts.

## Off by default; what it can do once on

The Agent is off until you turn on **Agent** in **Settings → Other**. Turning
it on keeps **Allow file edits and commands** (in the same place) at its
default, on, so from the first request the model you chose can use these
tools:

| Tool | With "Allow file edits and commands" on (default) | Off |
| --- | --- | --- |
| `list_directory`, `read_file`, `search_files` | yes | yes |
| `capture_screen` (when your request needs the screen) | yes | yes |
| web search (the provider's own, or a Tavily key), `fetch_url` (public HTTPS) | yes | yes |
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
