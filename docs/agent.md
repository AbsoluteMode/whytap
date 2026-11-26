# Whytap Agent

Tap **Right Command** to ask by text, hold it to ask by voice. The answer
appears in the island. The agent is built into Whytap: tools and memory stay
on your Mac, and inference runs at the provider you choose, with your key.

## Connect

1. In **Settings → Keys & models → API keys**, add an OpenRouter, OpenAI or
   Anthropic key.
2. Under **Models**, choose an **LLM** (and a **Speech** model for spoken
   requests). To give the Agent its own models, open **Advanced**: the
   **Agent** card holds both, Speech for your voice and Text for the answer.
3. In **Settings → Features → Agent**, turn on **Agent**. The same screen
   shows what is still missing, with the button that adds it.

Turning it on connects: it prepares the local workspace and checks that a key and a model are
present; it does not prove that the provider accepts the key. Requests are
billed by your provider. Whytap never switches to another provider or model on
its own.

## Speed

The Agent asks its model for the least reasoning the model accepts, so a
simple question is answered without long thinking; tool use stays. On
**OpenAI** that is `none`, `minimal` or `low` depending on the model; on
**Anthropic** low effort, with thinking turned off on Claude Haiku 5.5 and
Claude Sonnet 5, and on Claude Sonnet 5.5 its lowest setting, `between_tools`
(no thinking before answering), when the turn does not use Anthropic's web
search; on **OpenRouter** reasoning off where the model makes it optional,
else its lowest level. Models that do not take the setting keep their own
default. If a provider refuses the setting on a turn's first request, the
request is sent once more: on OpenAI at `low`, elsewhere without the setting.
Whytap does not read the error text, so any HTTP 400 on that first request
is sent once more, the same way; an error unrelated to the setting then
fails again with the same message. It is repeated only once, only for the turn's first request
(not after the search fallback), and a 400 is not billed and runs no tool. On Anthropic and OpenAI an answer can be up to 16,384 tokens;
a longer one says it reached the model's output limit.

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
| OpenRouter | `openrouter:web_search` | Exa at about $7 per 1,000 searches; `anthropic/` models use Anthropic's own search (about $10 per 1,000). Exa is chosen because OpenRouter caps it before a search runs, while other native engines ignore the cap. A workspace that locks out Exa refuses with 403; the Agent then retries once without OpenRouter's search and answers in text, because other engines cannot be capped. An error never switches the Agent to Tavily; pick Tavily in Search for that. Included in the cost OpenRouter reports |

The provider runs the search and sends its results to the model; Whytap
never sees a separate search request. "Searching the web" appears once the
provider's response reports a search, not while it runs. At most two built-in
searches (OpenAI: web calls) per request you make, across all of the Agent's
model calls for it; each provider enforces it before a search runs, and the
app stops offering the tool once two are spent. The pages the model cites appear as
source cards. If the model lists none itself, Whytap shows the provider's
citations (up to five).

**Settings → Keys & models → Models → Search** (under Speech and LLM) shows
what the Agent searches with now: *Anthropic · built-in*, *OpenAI · built-in*,
*OpenRouter · web*, *Tavily* or *Off — add a Tavily key*, with the price
below. Its menu works like the Speech and LLM menus: the built-in search of
the Agent model (the default) or Tavily.

**Tavily** serves a model without web search of its own (the Anthropic catalog
says so, or a few old OpenAI models such as `gpt-4.1-nano`) and anyone who
picks it in Search. If the provider refuses its own search on the first
request, the Agent answers without search on the same provider and says so;
it never switches to Tavily after an error. (The Agent runs only on Anthropic, OpenAI and OpenRouter today; Tavily
would also serve your own servers if they become Agent routes.) A saved Tavily
key alone never replaces built-in search.
Add the key in **Settings → Keys & models → API keys** (saving checks the key
without running a search). Only the search query goes to Tavily; the returned
excerpts and links go to your selected model. With neither, the
Agent has no search tool; asked to search, it answers in one line that web
search is off for this model and that a Tavily key in API keys turns it on.

## Off by default; what it can do once on

The Agent is off until you turn it on in **Settings → Features → Agent**. Turning
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
| `source_call`: read-only tools of the sources you connected | yes | yes |
| `whytap`: change Whytap's own settings, island tools and hotkeys, add Vocab and Filler words, To-do (next version after 2.2.26) | yes | yes |

Paths can be absolute or start with `~`; relative paths are inside the
agent's folder. Nothing confines the agent to that folder: it acts with your
macOS user's rights on any file you can read or write, and commands run as
you, with a 30-second limit and bounded output. **This is an action policy,
not a sandbox.** Turning the switch off removes writing and commands but
keeps reading files, searching, web access and screen capture. There is no
per-action approval yet; file contents, web pages and screenshots it reads
go to your model provider. Leave the switch off unless you want the Agent to
act on your Mac.

## Sources

**Settings → Features → Agent → Sources** connects what the Agent may search
when you ask: GitHub, Jira, a folder on this Mac, or MCP servers you already
use. **Add source…** offers, in this order:

1. **Found on this Mac:** MCP servers from Claude Code (`.claude.json` in the home folder,
   including project servers), Claude Desktop, Cursor (`.cursor/mcp.json` in the home folder),
   Codex (`.codex/config.toml` in the home folder) and VS Code (`mcp.json`), each with the exact
   command or address and an **Import** button, plus the GitHub CLI's sign-in
   when `gh` is signed in. Only the server entries are read, only while this
   sheet is open, and nothing is written back. A value the other app reads
   from its own environment (`${VAR}`) becomes a field to paste. A server is
   imported with its full command, arguments and working folder (a project
   server runs in its project folder) or not at all: servers that only speak
   the older SSE transport, insecure addresses, a secret on the command line
   or in the address, settings Whytap can't carry over yet (for example
   timeouts or tool filters), entries turned off in their app and Whytap's
   own server are listed with the reason instead.
2. **Services:** GitHub (GitHub's MCP server, read-only; **Create a token…**
   opens GitHub with read permissions prefilled) and Jira (site, e-mail and an
   API token; the site must be `https://your-team.atlassian.net`; runs
   `uvx mcp-atlassian` read-only, so it needs
   [uv](https://docs.astral.sh/uv/)).
3. **Folder:** names and text of regular files in that folder. Hidden files,
   build folders, symbolic links anywhere in a path, special files and
   credential-like files (`.env`, keys, `credentials…`) are never read, and
   paths cannot leave the folder. If the folder is moved or replaced, add it
   again.
4. **Custom server:** a command on this Mac with environment variables, or an
   `https://` address with headers. Put secrets in the variables or headers:
   a command line or address that carries one is refused.

After adding, Whytap connects and lists the tools. GitHub, Jira and folders
then make one harmless read call right away. An imported or custom server
shows *Connected · approve its tools in Details before the Agent uses them*:
Whytap can't check what its tools really do, so nothing is called until you
look at the classes and press **Approve tools**. The row then shows, for example, *Works · signed in as @octo · 23 read
tools*, or a reason (*not found*, *exited (status 1)*, *refused the
credentials*, *didn’t answer within 20 s*). Each row has a switch (off = the
Agent never sees it) and **Details…**: missing values, the tools with their
class, **Check again** and **Remove**. Browser sign-in (OAuth) is not
supported yet.

**What the Agent may call.** Every tool gets a class: **Read**, **Changes
things** or **Destructive**. Whytap decides it from the server's own hints,
the tool's name (create, send, merge, delete…) and, for tools neither
settles, one call to your Agent model with the tool list (names and
descriptions only, no data of yours) when you connect. Unknown tools are not
Read. You can change any class in Details. **Only Read tools are offered to
the Agent**; nothing that changes or deletes is ever called in this version.
If a server changes how a tool is described (Whytap re-lists the tools every
time it reconnects), that tool waits for **Approve tools** in Details.

**After reading a source, a request cannot act.** Text from issues, tickets or
files may try to give the model instructions. So once a request has read
anything from a source, only that source's Read tools and the answer remain:
file edits and reads, commands, `fetch_url`, web search, screen capture,
action cards, Whytap changes and every other source are removed and refused.
The answer's cards are only links the source itself returned; there is no
Insert card. Later questions in the same conversation keep these limits,
because its history now holds source text; start a new conversation for
those. When a source fails, the model gets a fixed sentence, never the
server's own text, and anything a server echoes of your token is masked.

**Secrets** (tokens, API keys, header values) are kept in Keychain. A local
server gets them only in its own process environment; a remote server only in
its own headers, over HTTPS (plain http only to this Mac and only without
credentials). Secrets never go on a command line or into an address. Removing
a source deletes its Keychain values.

Local servers start when the Agent or Settings first needs them and stop after
10 idle minutes, on sleep and when Whytap quits. Results are cut to 24,000
characters; a source call waits at most 10 seconds.

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
