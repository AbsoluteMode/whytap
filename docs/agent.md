# Whytap Agent

Tap **Right Command** to ask by text, hold it to ask by voice. The answer
appears in the island. The agent is built into Whytap: tools and memory stay
on your Mac, and inference runs at the provider you choose, with your key.

## Connect

1. In **Settings → API & Models → API keys**, add an OpenRouter, OpenAI or
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

On **Anthropic** and **OpenAI** the Agent asks the model for low effort, so a
simple question is answered without long thinking; tool use stays. Models that
do not take the setting keep their own default, and OpenRouter models are
unchanged. An answer can be up to 16,384 tokens; a longer one says it reached
the model's output limit.

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

**Settings → API & Models → Models → Search** (under Speech and LLM) shows
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
Add the key in **Settings → API & Models → API keys** (saving checks the key
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
