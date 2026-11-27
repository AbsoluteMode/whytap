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
related: [2026-10-22-native-agent.md, 2026-11-27-agent-sources-gated.md]
---

# The Agent searches connected sources, read tools only

> Gated off since 2026-11-27: `AgentSourcesGate.isEnabled` is false until
> the owner decides whether the feature stays. See
> `2026-11-27-agent-sources-gated.md`.

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
  (HTTP) or 90 s (stdio, since a first `npx`/`uvx` run downloads). Each is
  one deadline for the whole operation (starting the transport, initialize
  and its notice; every page of a list); a transport start that finishes after
  the deadline or a cancellation is closed at once. A failed connect answers
  its caller at the deadline and retires its transport separately: closing
  (however slow) is never awaited by the caller. Every stdin write checks
  the deadline before each write (even when the pipe has room) and HTTP before
  the request. Cancellation and deadlines stop the actual I/O: stdin writes
  poll every 50 ms and check cancellation (a write stopped part-way stops the
  server), HTTP sends are URLSession tasks that are cancelled, the HTTP
  session's closing DELETE is bounded to 3 s without reading its body, and
  folder reads check cancellation between 16 KB reads. `MCPDeadline` returns
  at the deadline without waiting for the operation to wind down. Servers
  start lazily, stop after 10 idle minutes, on sleep and with the app, and
  more than three exits in five minutes stop restarts until Check again.
- **Secrets:** Keychain account `integration.<source>.<NAME>` in the app's
  service. The manifest (`Application Support/whytap/assistant/sources.json`,
  0600) keeps names only. A stdio server gets them only in its environment,
  beside an allowlist of the app's own variables (no model keys) and the
  login shell's PATH; an HTTP server only in its own headers.
- **Credential policy** (`SourceCredentialPolicy`), one rule for import,
  tiles, the custom form, previews and launch: `problem` decides everywhere,
  `display` is the only preview and works on `redacted` (refused import
  entries keep only a redacted preview), and one per-argument test drives
  both. Names are split into words (`--api-key`, `GITHUB_TOKEN`,
  `accessToken`) and matched whole against credential words, the same way
  for a standalone flag and its next argument and for an inline
  `--flag=value` or `NAME=value`; a URL-shaped argument runs the address
  rule. An address with user info, a credential-named query key, a
  credential-looking or long opaque query value, fragment or path part is
  refused with the reason. The rule over-refuses rather than guesses (for
  example `--session <id>`).
- **Known values** (`SourceSecretMask`): each source's secret values
  (6 characters or longer, raw, JSON-escaped and percent-encoded, and the
  token part of an authorization header value) are masked out of everything a server wrote,
  where server data becomes text or metadata and before any clip derived from
  it. Protocol control data (the JSON-RPC envelope, ids, methods, negotiated
  version, pagination cursors, notices and the structural fields of results
  and tool entries) is parsed and routed unmodified, so a value that happens
  to equal a protocol token never changes negotiation, routing, paging or
  revocation. Data is redacted as a tree (strings, keys and numbers; a
  number becomes a mask as wide as its rendering) and then as rendered text
  (every JSON escaping included), so a description, result or error clipped
  later can never keep a fragment of a value. JSON-RPC error codes that render
  a value become 0; the stdio exit line is masked whole, then clipped. An stderr line whose start fell outside the 4 KB
  tail is dropped rather than shown;
  before it reaches Settings, the manifest or a model: tool results
  (including structured content), error results, JSON-RPC error and
  protocol text, exit detail, proof summaries and tool metadata (title,
  description, schema) before it is pinned, stored, classified or put in the
  Agent's prompt. A tool whose name carries a value is dropped.
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
  Approval is bound to the exact list: `MCPClient.listTools` returns the
  epoch it was read under and records each tool's pin (of the masked tool);
  a `list_changed` notice, an ended client or another HTTP session (a later
  answer naming a different `Mcp-Session-Id` ends the client) moves the
  epoch. `callTool` checks the caller's `SourceLease`, the epoch and the
  tool's pin in the same actor step that registers the request; the transport
  checks the lease and the still-current epoch again right before the first
  byte leaves (stdin write or HTTP request), and the answer is returned only
  if the lease, epoch and pin still hold when it arrives (a change notice that
  precedes it voids it). Every completed list starts a new epoch, and a list is
  applied only if it is still current after the list and the classification
  (otherwise it is read again, at most three times). Each source has
  a generation and a lease, both replaced by stop, disable, removal, new
  values, every class change and every approval; the old lease is revoked
  synchronously, so a revocation wins even after the controller's own
  check. After an answer the controller checks the lease and the tool's
  approved pin again and discards a late answer (server and folder alike).
  Every await before a launch (executable lookup, environment) is followed by
  a current-generation check before a process or session starts. Stopping all
  revokes every source first (including folders and sources loaded from disk
  that never connected) and then closes them together.
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
- **End of a turn that read a source:** both completion paths (finish_answer
  and a direct-Anthropic plain-text reply) go through
  `NativeAgentSources.taintedActions`: the only cards are link cards to
  addresses a source (or the provider's own search) returned verbatim in this
  request, whether listed in `sources` or written in the answer. No Insert
  text, paths, copy or command cards, and no other links become cards, so
  source content cannot become something pasted, opened or carrying data
  elsewhere; links stay as text in the answer. The conversation records the
  sources it read (`NativeAgentConversation.sourceReads`), and its later
  requests (resumed within the resume window) start with the same
  restrictions, because its saved history carries source-derived text. A
  new conversation starts clear.
- **Proof:** after connecting, one harmless read call (preset, model
  suggestion, or a Read tool without required parameters) and a one-line
  result in the row ("Works · signed in as @octo · 23 read tools").
- **Import from this Mac** reads only server entries of `.claude.json` in the home folder
  (user and project), Claude Desktop, `.cursor/mcp.json` in the home folder,
  `.codex/config.toml` in the home folder and VS Code's `mcp.json`, only when Add source
  opens, and writes nothing back. `${VAR}` and `${input:…}` values become
  "Needs a value" fields. An entry is imported with its complete launch
  parameters (Codex multi-line arrays, `cwd`, and a project server's project
  folder as its working folder) or listed with a reason and not offered.
  Each entry is checked against one shape before a draft exists: allowed
  keys only (JSON: type, command, args, env, url/serverUrl, headers, cwd,
  disabled, enabled, description; Codex: command, args, env, env_vars, cwd,
  url, bearer_token_env_var, http_headers, env_http_headers, enabled), every
  value of its type (args a list of text, env and headers maps of text), one
  transport (exactly one of command or address, matching an explicit type;
  local keys only with a command, headers only with an address), and enabled.
  Refused with a reason: timeouts and tool filters (Whytap applies its own),
  an entry turned off in its app, unknown or mistyped keys, SSE or other
  transports, credentials in argv or the address, TOML Whytap doesn't
  understand (unknown escapes, multi-line strings, arrays of tables, dotted
  keys in inline tables, repeated keys) and Whytap's own server. A declared
  working folder that can't be set stops the launch.
- **Tiles:** GitHub uses GitHub's remote MCP server with a pasted
  fine-grained token (the token page opens with read permissions prefilled)
  or the GitHub CLI's existing sign-in, always with `X-MCP-Readonly: true`.
  Jira runs `uvx mcp-atlassian` with `READ_ONLY_MODE=true`.
- **Folder** sources are built in (no MCP): name and text search and a
  bounded read inside the folder. When added, the folder's real path and its
  device and inode are stored (`FolderIdentity`). Every listing, count,
  search and read reaches it from `/` one component at a time with
  `O_NOFOLLOW` and requires the same device and inode, so a moved, replaced
  or relinked folder or ancestor is refused ("add the folder again"); below
  it each entry is opened with `openat` and `O_NOFOLLOW` and checked with
  `fstat` on the descriptor (directories and regular files only). The walk
  reads directories through their descriptors and reports a name only after
  its file passed that open, so a change between listing and opening cannot
  substitute another object. Hidden files, build folders and credential-like
  files are never read; offsets must be whole numbers from 0 to 64 MB.
- **Untrusted decoding and transport:** JSON numbers become integers only by
  exact conversion (1e300, NaN and fractions are not integers); the 16 MB
  stdio limit applies to every completed line before delivery; writes to a
  server's stdin are non-blocking under the request's deadline and messages
  over 1 MB are refused.

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
- Second builder review (ticket 629), each point as a class: a table of
  15 command-line credential forms and 6 address forms through the JSON and
  Codex importers (accepted, and refused for another reason first), the
  custom form, `problem`, `display`, `redacted`, `add` and a hand-edited
  manifest's launch, asserting the sentinel never appears; a server echoing
  its token in tool metadata, a tool name, structured content, an error
  result, a JSON-RPC error and stderr, checked across the manifest, statuses,
  the classification prompt, the Agent's prompt and tool schema, results and
  errors; 6 await points (executable lookup, environment, connect, list,
  classification, the call itself) × 4 revocations (disable, remove,
  reclassify, stop all); dispatch refused for a wrong epoch, pin or a revoked
  lease; another HTTP session ending the client; both completion paths after
  a source read and a later request of the same conversation; every folder
  entry kind (regular, link inside, link outside, link to a folder, FIFO,
  hidden, credential, build folder) × count, search by name and content and
  read, a replaced folder or ancestor, cancelled reads; 20 JSON and 19 Codex
  forms Whytap can't carry; the working folder set or the launch refused;
  cancelled and timed-out writes, one handshake deadline, and the deadline
  helper not waiting.
- Third builder review (ticket 644), each remaining class: a server places
  the known value across every clip limit (tool description, result,
  structured content, error result for the model, proof line, JSON-RPC error,
  exit detail, the stderr tail, the protocol string) and no surface keeps a
  10-character fragment; a call revoked while held at the transport's send
  boundary sends nothing; an answer preceded by a change notice is not
  returned; a list overtaken by a notice during classification is read again;
  a folder read in flight from a source loaded from disk is discarded by
  disable, remove, reclassification and stop all; a 25 ms connect over a
  250 ms transport start returns at its deadline and the late start is closed;
  an expired or unauthorized write reaches neither a writable pipe nor an HTTP
  request. Mutating the decode mask and the answer check makes these fail.
- Fourth builder review (ticket 685), as classes, plus the builder's own
  fixture (`AgentSourceQueueReviewTests`): three values (numeric, escaped
  text, plain) in every result placement (text, structured string, key,
  number, nested number, resource text, resource link) at every offset across
  the clip; tool descriptions, schema defaults and JSON-RPC error messages and
  codes; 23 protocol tokens used as masks across connect, paged listing,
  calls and change-notice revocation; five connect failures (no answer, start
  error, invalid response, unsupported protocol, cancellation) with a slow
  transport close. Re-masking the envelope or awaiting close fails them.
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
- Carrying Codex timeouts or other apps' enablement flags as ignored keys:
  the import would silently differ from the source app, so such entries are
  refused instead.
- Keeping action cards, Insert text or Markdown-derived cards after a source
  read, or clearing the restriction at the next request of the same
  conversation: source text would still steer what is pasted or opened.

## Not in this iteration

Browser sign-in (OAuth), the Map and `find`, adapters beyond the proof call,
Watch, Act (preview and Confirm), source content in backups, legacy SSE
servers, the rename to Assistant, and the plan's setup-time measurements.

2026-11-26 · branch `feature/assistant-sources`
