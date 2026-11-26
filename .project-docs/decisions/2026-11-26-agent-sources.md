---
id: agent-sources-2026-11-26
type: decision
title: The Agent searches sources the user connects through Whytap's own MCP client, with read tools only
summary: Iteration 1 of the Assistant plan. Settings → Features → Agent → Sources connects MCP servers (imported from Claude Code, Claude Desktop, Cursor, Codex or VS Code, GitHub and Jira tiles with a pasted token, a custom command or address) and folders on this Mac. A hand-written MCP client in the native runtime (stdio and Streamable HTTP with static headers) lists and calls tools. Every tool gets a class in app code; the Agent is offered only approved Read tools through one strict source_call function. Secrets live in Keychain and reach a server only through its process environment or its own HTTP headers. Imported and custom servers are called only after the user approves their tools. After a request reads source content, only that source's Read tools and the answer remain for the rest of that request.
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
  login shell's PATH; an HTTP server only in its own headers.
- **Credential policy** (`SourceCredentialPolicy`), one rule for import,
  tiles, the custom form, previews and launch: a command line with a
  secret-looking argument (a token prefix, `NAME=value` with a secret name,
  or a value after `--token`, `--api-key`, `--header` and similar flags) and
  an address with user info, a secret-named query key or a secret-looking
  path part are refused with the reason; previews mask by the same test.
  Credentials never go over plain http, even to this Mac. A manifest edited
  by hand to carry an argv secret does not launch. The Jira tile accepts only
  an https address with only a host and optional port, and an e-mail address; tokens and values are one line,
  bounded. An exit reason shown in Settings masks the source's secret values.
  Nothing in this module logs.
- **Tool classes** (Read, Local change, Changes things, Destructive),
  assigned in app code by `SourceToolClassifier`: the user's choice, else
  the strictest of the server's hints (`readOnlyHint`, `destructiveHint`), a
  name rule (write and delete verbs) and one model suggestion. The model
  call (plan §1.1) uses the Agent's own route once per connection, only for
  tools nothing else settles, with names, descriptions and parameter names
  and no user data, and also proposes the proof call. A suggestion can make
  an unhinted tool Read but never overrides a write signal; unknown tools
  are never Read.
- **Explicit trust:** a reviewed tile (GitHub with `X-MCP-Readonly`, Jira
  with `READ_ONLY_MODE`) and a folder are trusted on connect. For an imported
  or custom server Whytap cannot check what a tool really does, so no hint or
  model suggestion approves anything: every Read tool waits for Approve tools
  in Details, and no tool (not even the proof) runs before that.
- **Pinning at the current connection:** each decision stores a hash of the
  tool's name, title, description, schema and hints. Every new process or HTTP
  session re-lists and re-classifies before the first call; a
  `tools/list_changed` notice holds every tool until a list that started
  after the notice completes, so a failed or concurrent re-list never
  revalidates old pins. A changed tool is unavailable until approved.
  Each source has a generation bumped by stop, disable and removal; a check
  re-verifies generation, enablement, the live client, validation and the
  current pin after every await and immediately before the proof and every
  Agent call, and a result arriving after revocation is discarded. Removal
  revokes before stopping; stopping all ends connections in flight too.
- **The Agent** gets one strict function, `source_call(tool, arguments)`.
  `tool` is an enum of approved Read tools of enabled sources; each tool's
  compact signature is in the system prompt (bounded to 10,000 characters),
  so many servers never break the provider's strict-schema rule. The
  controller checks class, approval and enablement again at every call.
  Tools of other classes never reach the model.
- **Taint rule:** once a request has received text from a source (a result
  or a tool error result), `write_file`, `run_command`, `fetch_url`, Tavily
  and the provider's own web search, local file reads and listings, screen
  capture, Case key listings, action cards and Whytap app control leave the
  catalog and are refused for the rest of that request, and `source_call` is
  narrowed to the sources already read. Content from source A therefore
  cannot be sent to source B or anywhere else; the remaining channel is the
  same source's own Read tools. Failures (exit, server error, unsupported
  protocol, timeouts) reach the model only as fixed text with no server
  output, so they do not taint; Settings may show the masked detail.
- **Proof:** after connecting, one harmless read call (preset, model
  suggestion, or a Read tool without required parameters) and a one-line
  result in the row ("Works · signed in as @octo · 23 read tools").
- **Import from this Mac** reads only server entries of `.claude.json` in the home folder
  (user and project), Claude Desktop, `.cursor/mcp.json` in the home folder,
  `.codex/config.toml` in the home folder and VS Code's `mcp.json`, only when Add source
  opens, and writes nothing back. `${VAR}` and `${input:…}` values become
  "Needs a value" fields. An entry is imported with its complete launch
  parameters (Codex multi-line arrays, `cwd`, and a project server's project
  folder as its working folder) or listed with a reason and not offered:
  SSE-only servers, insecure or credential-bearing addresses, argv secrets,
  keys Whytap can't carry (for example Codex `enabled_tools`, JSON
  `envFile`), TOML it can't read (multi-line strings, arrays of tables),
  non-text arguments and Whytap's own server.
- **Tiles:** GitHub uses GitHub's remote MCP server with a pasted
  fine-grained token (the token page opens with read permissions prefilled)
  or the GitHub CLI's existing sign-in, always with `X-MCP-Readonly: true`.
  Jira runs `uvx mcp-atlassian` with `READ_ONLY_MODE=true`.
- **Folder** sources are built in (no MCP): name and text search and a
  bounded read inside the folder. The policy is enforced on the opened
  object: the path is walked from the selected folder with `openat` and
  `O_NOFOLLOW` (a link in any component, or the folder itself replaced by a
  link, is refused), only a regular file passes `fstat`, reads are bounded
  `pread`s, and search uses the same opener. Hidden files, build folders and
  credential-like files are never read; offsets must be whole numbers from 0
  to 64 MB.
- **Untrusted decoding and transport:** JSON numbers become integers only by
  exact conversion (1e300, NaN and fractions are not integers); the 16 MB
  stdio limit applies to every completed line before delivery; writes to a
  server's stdin are non-blocking with a 10 s deadline and messages over 1 MB
  are refused; an abandoned request cancels its HTTP send as well as the wait;
  folder calls stop after 10 s.

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
- Builder review of PR #491 (ticket 621), one regression per point: the
  builder's argv sentinel masked and not importable, custom argv and URL
  credentials refused, secret headers over loopback http refused, invalid
  Jira sites and e-mails, a hand-edited manifest with an argv secret not
  launched; a tool changed while disconnected, a failed re-list and a
  concurrent re-list after `list_changed` never reach the server, disabling
  during classification and removing or stopping all during a slow connect
  leave nothing running or approved; a custom server is not called and not
  offered before approval even when a model calls every tool Read, a tile
  proves at once; injected text in an exit detail, server error or protocol
  string never reaches the model; after reading source A, source B leaves the
  enum and its call is refused; a symlinked file, a symlinked folder and a
  FIFO are refused by read and search, bad offsets fail; Codex multi-line
  arguments and `cwd`, project folders, unknown keys and unreadable TOML;
  1e300/NaN integers, absurd JSON-RPC ids, a 17 MB single line, and a write
  to a process that never reads.
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
- Moving an argv secret to Keychain and putting it back on the command line
  at start (the first version): it stays visible to process listings and the
  preview had to mask it by a second, different test.
- Trusting an imported server's own `readOnlyHint` or a model suggestion on
  first connect: both come from the server's own descriptions.

## Not in this iteration

Browser sign-in (OAuth), the Map and `find`, adapters beyond the proof call,
Watch, Act (preview and Confirm), source content in backups, legacy SSE
servers, the rename to Assistant, and the plan's setup-time measurements.

2026-11-26 · branch `feature/assistant-sources`
