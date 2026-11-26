---
id: agent-sources-2026-11-26
type: decision
title: The Agent searches sources the user connects through Whytap's own MCP client, with read tools only
summary: Iteration 1 of the Assistant plan. Settings → Features → Agent → Sources connects MCP servers (imported from Claude Code, Claude Desktop, Cursor, Codex or VS Code, GitHub and Jira tiles with a pasted token, a custom command or address) and folders on this Mac. A hand-written MCP client in the native runtime (stdio and Streamable HTTP with static headers) lists and calls tools. Every tool gets a class in app code; the Agent is offered only approved Read tools through one strict source_call function. Secrets live in Keychain and reach a server only through its process environment or its own HTTP headers. After a request reads source content, file edits, commands, web access and Whytap changes are removed and refused for the rest of that request.
status: confirmed
tags: [agent, native-agent, sources, mcp, security, privacy, keychain, assistant]
canonical_for: [agent-sources, mcp-client, source-tool-classes, source-taint-rule]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: "On 2026-11-26 the orchestrator, for the maintainer, assigned ORCH-TASK 37 spec REV 3: implement iteration 1 (connecting sources) of docs/plans/2026-11-26-assistant.md into the current on-demand Agent, without the rename, Map, Profile, Watch or Actions."
    confirmed_at: 2026-11-26
  - type: repository
    reference: docs/plans/2026-11-26-assistant.md
    confirmed_at: 2026-11-26
  - type: url
    reference: https://modelcontextprotocol.io/specification
    confirmed_at: 2026-11-26
  - type: url
    reference: https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp/set-up-the-github-mcp-server
    confirmed_at: 2026-11-26
  - type: url
    reference: https://github.blog/changelog/2025-08-26-template-urls-for-fine-grained-pats-and-updated-permissions-ui
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Assistant/Connections/SourcesController.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentSources.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/Assistant/SourcesControllerTests.swift
    confirmed_at: 2026-11-26
related: [2026-10-22-native-agent.md]
---

# The Agent searches connected sources, read tools only

## Context

The plan (`docs/plans/2026-11-26-assistant.md`, iteration 1) asks for
sources that take a minute to connect, under the current Right Command
Agent, so the owner can test how well it answers from them. The Agent is
Whytap's native runtime (direct HTTP to OpenRouter, OpenAI or Anthropic), so
OpenCode's MCP support does not help: Whytap needs its own MCP client.

## Decision

- **MCP client** (`Assistant/Connections/MCPClient.swift`), hand-written:
  `initialize`, paginated `tools/list`, `tools/call`, `ping`,
  `notifications/tools/list_changed`, `notifications/cancelled`. No
  sampling, elicitation or roots: a server cannot ask our model anything.
  Transports: stdio (`MCPProcess`, the `NotifyProcess` hosting pattern with
  the guard's lifeline moved to fd 3 so stdin carries JSON-RPC) and
  Streamable HTTP (JSON or SSE replies, `Mcp-Session-Id`,
  `MCP-Protocol-Version`, a same-origin-only redirect rule, HTTPS except for
  this Mac). Static token/header auth only; browser sign-in is later.
- **Bounds:** 16 MB per message, tool results clipped to 24,000 characters
  before any model sees them, Agent calls 10 s, proof 15 s, connect 20 s
  (HTTP) or 90 s (stdio, since a first `npx`/`uvx` run downloads). Servers
  start lazily, stop after 10 idle minutes, on sleep and with the app, and
  more than three exits in five minutes stop restarts until Check again.
- **Secrets:** Keychain account `integration.<source>.<NAME>` in the app's
  service. The manifest (`Application Support/whytap/assistant/sources.json`,
  0600) keeps names only. A stdio server gets them only in its environment,
  beside an allowlist of the app's own variables (no model keys) and the
  login shell's PATH; an HTTP server only in its own headers. A secret an
  imported config passed on the command line is moved to Keychain and put
  back into argv at start; the row warns that process listings can see it.
  An exit reason shown in Settings masks the source's secret values. Nothing
  in this module logs.
- **Tool classes** (Read, Local change, Changes things, Destructive),
  assigned in app code by `SourceToolClassifier`: the user's choice, else
  the strictest of the server's hints (`readOnlyHint`, `destructiveHint`), a
  name rule (write and delete verbs) and one model suggestion. The model
  call (plan §1.1) uses the Agent's own route once per connection, only for
  tools nothing else settles, with names, descriptions and parameter names
  and no user data, and also proposes the proof call. A suggestion can make
  an unhinted tool Read but never overrides a write signal; unknown tools
  are never Read.
- **Pinning:** each decision stores a hash of the tool's name, title,
  description, schema and hints. A changed tool, or a new Read tool after
  the first connection, is unavailable until the user approves it in
  Details.
- **The Agent** gets one strict function, `source_call(tool, arguments)`.
  `tool` is an enum of approved Read tools of enabled sources; each tool's
  compact signature is in the system prompt (bounded to 10,000 characters),
  so many servers never break the provider's strict-schema rule. The
  controller checks class, approval and enablement again at every call.
  Tools of other classes never reach the model.
- **Taint rule:** once a request has received text from a source (a
  result, a tool error or a server error message), `write_file`,
  `run_command`, `fetch_url`, Tavily and the provider's own web search, and
  Whytap app-control writes leave the catalog and are refused for the rest
  of that request. Read-only tools stay.
- **Proof:** after connecting, one harmless read call (preset, model
  suggestion, or a Read tool without required parameters) and a one-line
  result in the row ("Works · signed in as @octo · 23 read tools").
- **Import from this Mac** reads only server entries of `.claude.json` in the home folder
  (user and project), Claude Desktop, `.cursor/mcp.json` in the home folder,
  `.codex/config.toml` in the home folder and VS Code's `mcp.json`, only when Add source
  opens, and writes nothing back. `${VAR}` and `${input:…}` values become
  "Needs a value" fields. SSE-only servers, insecure addresses and Whytap's
  own server are listed with a reason, not imported.
- **Tiles:** GitHub uses GitHub's remote MCP server with a pasted
  fine-grained token (the token page opens with read permissions prefilled)
  or the GitHub CLI's existing sign-in, always with `X-MCP-Readonly: true`.
  Jira runs `uvx mcp-atlassian` with `READ_ONLY_MODE=true`.
- **Folder** sources are built in (no MCP): name and text search and a
  bounded read inside the folder; hidden files, symbolic links, build
  folders and credential-like files are never read.

## Why

- A strict-schema catalog must be one mode for every function (see the
  native agent decision); MCP input schemas are arbitrary. One enum-gated
  function keeps the strict catalog and makes "only Read tools reach the
  model" a property of the schema as well as of the executor.
- "No model ever calls a write tool" (plan §5) is enforced by never offering
  one: the Act iteration will add preview and Confirm for outward tools.
- The taint rule blocks rather than asks because the Agent has no
  confirmation surface for tool calls today; blocking is the stricter form
  of the plan's question 5 and needs no new UI. Asking can replace it when
  Act adds the confirmation panel.
- Without Whytap servers, a pasted token is the easiest honest route for
  GitHub and Jira; import covers people who already use coding tools.

## What we tested

- A real stdio server (Perl script) for list with pagination, calls,
  environment-only secrets, non-JSON stdout, a 100,000-character result,
  timeout, cancellation, a crash mid-call with masked stderr, exit at start,
  an unsupported protocol version, a missing executable and the lifeline.
- Stubbed Streamable HTTP: JSON and SSE replies, session and protocol
  headers, 401, an oversized body and the HTTPS rule.
- The controller end to end: Keychain only, 0600 manifest without values,
  classes, proof, Read-only gating (a write or destructive tool never reaches
  the server), user overrides, pinning and approval, missing values,
  restart after a crash, removal deleting Keychain items, folder escapes and
  credential files.
- Import fixtures for every app: absent, broken and present files,
  placeholders, argv secrets, duplicates, SSE and Whytap's own server.
- The Agent loop: a source search answered; an injected instruction in a
  source result followed by `run_command`, `write_file` and `fetch_url`
  calls runs nothing and the next request's catalog lacks those tools and
  the provider search; an unlisted tool ID never reaches the source.

## Rejected

- The official Swift MCP SDK: four more packages (swift-nio and others).
- Offering each MCP tool as its own function: breaks the strict catalog and
  grows every request with many schemas.
- Letting the classification model decide alone: tool descriptions are
  untrusted, so its answer can only relax an unknown tool, never a write
  signal.
- Asking (instead of refusing) after taint in this iteration: no Agent
  confirmation surface yet.
- Storing env values in the manifest when they look harmless: every
  imported value is treated as a secret.

## Not in this iteration

Browser sign-in (OAuth), the Map and `find`, adapters beyond the proof call,
Watch, Act (preview and Confirm), source content in backups, legacy SSE
servers, the rename to Assistant, and the plan's setup-time measurements.

2026-11-26 · branch `feature/assistant-sources`
