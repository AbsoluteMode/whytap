# Whytap Agent

Tap **Right Command** to ask by text, hold it to ask by voice. The answer
appears in the island. The agent is built into Whytap: tools and memory stay
on your Mac, and inference runs at the provider you choose, with your key.

## Connect

1. In **Settings → API & Models → API keys**, add an OpenRouter, OpenAI or
   Anthropic key.
2. Under **Models**, choose the **Agent** model (and **Agent voice** for spoken
   requests).
3. In **Settings → Agents**, click **Connect**.

Connect prepares the local workspace and checks that a key and a model are
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

## Files and commands

The agent can edit files and run commands by default. Turn off **Allow file
edits and commands** in **Settings → Agents** to block both. This is an action
policy, not a sandbox. Commands stop after 30 seconds. Approval modes are a
later phase.

## Memory

The agent's folder is `~/Library/Application Support/whytap/agent` (**Open
folder** in Settings → Agents):

- `AGENTS.md` is long-term memory that you or the agent can edit.
- Recent text context resumes for 15 minutes, limited to six question/answer
  pairs and 12,000 characters, for the same provider, model and endpoint.
- Screenshots, tool output and reasoning are not written into that history.

What the agent sends and where: [Privacy](privacy.md).
