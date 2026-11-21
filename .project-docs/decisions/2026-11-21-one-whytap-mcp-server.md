---
id: one-whytap-mcp-server
type: decision
title: One Whytap MCP server for application tools and Case key names
summary: `whytap mcp` serves the application tools and the names-only Case tools from one process; each Case call is the same broker request as before, so registration, scope and approvals are unchanged. `app mcp` and `case mcp` keep working, Connect writes the one `whytap` entry and retires its older `case` entry.
status: confirmed
tags: [agents, plugin, mcp, case, connect]
canonical_for: [whytap-mcp-entry-point]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 Maxim asked why an agent needs two Whytap MCP servers (`whytap app mcp` and `whytap case mcp`) and decided to merge them into one, without weakening Case security or breaking existing commands.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/WhytapCaseKit/AppControlMCPServer.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/WhytapCLI/main.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Case/Clients/CaseClientConnector.swift
    confirmed_at: 2026-11-21
  - type: repository
    reference: plugins/whytap/mcp.json
    confirmed_at: 2026-11-21
related: [2026-10-21-app-control-plugin.md, 2026-10-21-case-connect-claude-code.md, 2026-11-20-harness-access.md]
---

## Context

Since 2026-10-21 the plugin started two stdio servers from the same helper:
`whytap app mcp` (settings, models, To-do, meetings) and `whytap case mcp`
(Case project and key names). Manual setup therefore needed two lines per
harness in README and the app-control guide, and Case -> Connect wrote a
third-party-looking `case` entry next to the user's `whytap` one. The split
existed only because the two interfaces have separate authorization paths,
not because they need separate processes.

## Decision

- `whytap mcp` is the one server. It is `AppControlMCPServer` with the
  `CaseMCPServer` attached: `tools/list` returns every `whytap_*` tool followed
  by `case_list_projects` and `case_list_keys` exactly as the Case server
  defines them; a `case_*` call goes to `CaseMCPServer.callTool`, the same code
  `case mcp` runs. `initialize` names the server `whytap` and carries both
  guides (the Case guide with the helper's real path for `case run`). The
  agent's own `screen-mcp` never gains Case tools.
- `whytap app mcp` and `whytap case mcp` stay unchanged for hosts already set
  up with them. `whytap mcp <anything>` prints usage and exits 64.
- `plugins/whytap/mcp.json` has one server, `whytap` -> `mcp` (plugin 0.3.0).
- Case -> Connect writes `whytap` -> `<helper> mcp` for the clients it
  offers: Claude Code (`claude mcp add -s user`) and Cursor
  (`.cursor/mcp.json` in the home folder). Codex stays out of the Connect
  list (2026-10-21 Case Connect decision): it is set up with the README's
  `codex mcp add whytap -- <helper> mcp`, and its Case tools answer only for
  a registration kept from an earlier build. The Codex connector below serves
  such a kept registration (Disconnect) and follows the same rules.
- **Ours means one thing:** a stdio entry whose command is an absolute path
  equal to this app's helper path once both are standardized and their
  symlinks resolved, with arguments `mcp`, `app mcp` or `case mcp` (the
  older `case` entry: only `case mcp`). No basename or prefix matching:
  `/opt/local/bin/whytap-metrics`, a copy of Whytap in Downloads, a beta
  helper or a bare `whytap` on PATH are someone else's. Such an existing
  `whytap` entry of ours is replaced; any other, or one that cannot be read
  for certain, stops Connect with a message naming it and no changing CLI
  call. Replacing never leaves the person without the entry that worked:
  `codex mcp add` replaces a name in one write, so Codex is never asked to
  remove it first; `claude mcp add` refuses an existing name, so ours is
  removed, and a refused add puts the previous command and arguments back
  with `claude mcp add`, reporting the add's failure (or that the restore
  failed too). An entry already `<helper> mcp` (exact path) is left as it
  is, whatever else it sets. An older entry of ours is replaced only when it
  is plain: nothing but stdio, command, args and an empty env (for Codex:
  every other field `null` or `false` in `codex mcp get --json`, apart from
  `env_vars: []`, which is how Codex reports none; an explicit empty
  `enabled_tools`, `disabled_tools` or `env` is a setting). Anything more is the
  person's own setting: a rewrite would drop it and a restore would have to
  pass it on a command line, so Connect refuses before any change. Our older
  `case` entry is removed only when plain. After
  adding, our older `case` entry is removed, best effort; any other `case`
  entry is never touched.
- **Codex is read through Codex.** `codex mcp add` replaces a server by name,
  so Connect first runs the read-only `codex mcp get <name> --json` (Codex's
  own TOML parser decides escapes, inline tables, comments) through a
  separate reading seam, never the runner that changes settings. Exit 0 with
  that name's JSON gives the entry; a failure whose last stderr line is
  exactly Codex's "No MCP server named '<name>' found." means absent; any
  other answer, a newer wording, a timeout or more than 256 KB means
  uncertain, which refuses. Claude Code's `.claude.json` (home folder) and Cursor's
  `mcp.json` are JSON read by the system parser (escaped keys included); an
  unreadable file or a non-object `mcpServers` refuses as well.
- Disconnect removes only our older `case` entry, and only when plain (the
  same rule as Connect). The `whytap` entry stays.

## Why

- **Same authorization, not a merged one.** The broker decides who is asking
  from the helper process's parent chain (`CaseCallerResolver`) and the
  audit-token check of the bundled helper, never from its arguments. A
  `case_*` call from `whytap mcp` is the same `.listKeys` / `.listProjects`
  request over the same socket, from the same kind of process, as from
  `case mcp`, so registration, project scope, Accept/Bypass and approvals
  apply unchanged. Application controls stay `.appControl` requests and never
  load the vault; meeting tools keep the harness access gate (the helper's
  direct parent, unchanged by the merge). No check was relaxed to merge them.
- **Nothing new can read a value or run a command.** The unified server can
  send only `.appControl`, `.listKeys` and `.listProjects`; `.resolveRun`
  remains reachable only from `whytap case run` in the agent's own terminal.
  A test asserts that no request the server sends is `.resolveRun`.
- **One line per harness.** README and the guide give one `mcp add` command
  each for Claude Code and Codex.
- **Keeping the old commands** costs nothing (they are the same classes) and
  avoids breaking every host configured since October.
- **Disconnect keeps `whytap`.** The entry is now the general Whytap server
  that the plugin and README also add. Removing it on Disconnect would remove
  application controls a person may have set up by hand (Connect cannot tell
  a hand-made `whytap mcp` entry from its own). Access is already closed at
  the broker: an unregistered client gets "Access denied" from the Case tools.
- **Reading through the client, not a parser of our own.** Two builder
  reviews showed a hand-written TOML reader keeps missing valid forms
  (a comment after a header, an inline table, a `\u` escape in a quoted key).
  No TOML library is in the dependencies; adding one for one read is more
  surface than asking the Codex that will apply the change. `codex mcp get
  --json` returns only the named entry (its env values stay in memory, are
  parsed and dropped, never logged). `claude mcp get` has no JSON output, so
  Claude Code's JSON file is read directly.
- **Exact path, no look-alikes.** A basename rule took
  `/opt/local/bin/whytap-metrics` for ours and would have replaced it. A
  moved or beta Whytap is not replaced either; the person removes that entry
  once, which is safer than guessing.
- **Best-effort cleanup.** If removing the older `case` entry fails, the host
  keeps a working but duplicate Case server; failing Connect for that would
  report a broken connection that in fact works.

## What was tested

- `WhytapMCPServerTests`: one listing with all 14 application tools and both
  Case tools (Case definitions identical to `case mcp`'s); `initialize` with
  both guides; Case calls send only `.listKeys` / `.listProjects` and never
  render values, even from a misbehaving broker; an unregistered client gets
  the same "Access denied" text as `case mcp` while `whytap_get_state` on the
  same server works; no Whytap -> clear unavailable message; broken input
  (non-JSON, arrays, wrong argument types, unknown tools, bad ids, oversized
  lines, notifications) gets an error or no reply and never reaches the
  broker; a stdio session survives a bad line, answers both kinds of tool and
  asks for harness access once; `app mcp` and `case mcp` still serve only
  their own tools; `screen-mcp` never lists Case tools.
- `CaseClientConnectorTests`: Connect writes `whytap` -> `mcp` for Claude
  Code and Cursor (and the kept Codex path); migrates our older `case` entry; replaces our own
  `whytap` (`mcp`, `app mcp`, `case mcp`, also through a symlink); refuses
  with zero changing CLI calls and the file unchanged: look-alike helpers
  (`whytap-metrics`, a Downloads copy, a beta helper, bare `whytap`,
  `<helper>/../whytap-metrics`), a JSON-escaped `why\u0074ap` key, URL
  servers, other subcommands, missing or odd `args`, unreadable files, and
  for Codex every answer it cannot prove (empty, not JSON, another name,
  broken config, other wording, truncated, failed read); leaves any foreign
  `case` alone; a failed cleanup keeps the connection; Disconnect removes
  only our older entry and nothing without a helper path.
- `CodexCLIConfigReadingTests` (skipped without Codex) runs the installed
  `codex mcp get --json` on fixture configs in a temporary HOME, changing
  commands going to a fake runner: the builder's header comment, inline
  table, `[mcp_servers."why\u0074ap"]` and `whytap-metrics` fixtures, a
  literal key with CRLF, dotted keys and a URL server are each read by Codex
  (asserted) and refused with no changing call; nothing configured adds once;
  our own `app mcp` entry plus our multi-line `case` entry are replaced and
  migrated. Run with codex-cli 0.170.0.
- The built helper outside an app bundle (no broker client, nothing launched):
  `whytap mcp` lists 16 tools and answers a bad line with a parse error;
  `app mcp` lists 14, `case mcp` 2; `whytap mcp extra` exits 64.
- Builder review 3 (queue run 16213): a successful remove followed by a
  refused add lost the working entry in both Codex and Claude Code. Codex now
  adds without removing (a test runs the real `codex mcp add` over our
  `app mcp` entry and reads it back replaced); Claude Code tests cover the
  restore of the previous command, a failed restore reported as such, and
  an already-current entry left untouched.
- Builder review 4 (queue run 44836): the first restore used `claude mcp
  add-json` with the whole previous entry, putting its env values in a
  process's arguments. Restore now passes only command and arguments, and an
  entry with env values, a non-object env or any other field is refused
  before removal; the test asserts no command carries a synthetic value.
- Builder review 5 (queue run 66143): Codex Connect rewrote an already
  current entry and an older `app mcp` one, re-enabling a disabled server
  and dropping its 45-second startup timeout; Cursor dropped env. Tests now
  cover, for all three clients, a current entry with settings left untouched,
  a customized older entry refused with zero changes, and a customized
  `case` entry left alone; the real Codex CLI reads `startup_timeout_sec`,
  `enabled = false` and an env table as customized.
- Builder review 6 (queue run 93934): Disconnect still removed a customized
  older `case` entry in Claude Code and Cursor. It now applies the plain rule
  too; a test covers both hosts, and a plain entry is still removed.
- Builder review 7 (queue run 93934, second probe): an explicit
  `enabled_tools = []` read as plain, so Connect rewrote and Disconnect
  removed such entries. Only `null`/`false` count as unset now (plus Codex's
  `env_vars: []`); fake and real-CLI tests cover empty tool lists and env.
- Builder reviews (queue runs 7446, 44301) found the earlier hand-written
  TOML reader missing a commented header, an inline table and a `\u`
  escaped key, and a basename rule accepting `whytap-metrics`. Both were
  replaced as described above; all four fixtures are in the tests.
- New-user stress test (2026-11-22; report outside the repository): 50
  scenarios in Russian and English, written and graded by one Codex as a
  new user, answered by another Codex through the installed 1691 helper's
  `app mcp` + `case mcp` (tool definitions byte-identical to this branch's
  `whytap mcp`), then re-run on the branch helper. Codex refused both Case
  tools: without MCP annotations they count as destructive and open-world,
  and needed an approval a non-interactive run could not ask for. They are
  now annotated read-only (a test checks every tool declares its effects).
  Descriptions now say which settings exist and that hotkeys, meeting
  recording and displays do not; that meeting search does not translate and
  `to` includes the whole day; that tasks have no due date; that nothing
  deletes tasks or meetings; and that Case keys are separate from Whytap's
  provider keys. A helper outside the app bundle now says to point the MCP
  entry at the installed app instead of "Open the Whytap app".
- Not tested: a live Claude Code / Codex / Cursor host against the installed
  app, and Connect against real client configurations. Those are acceptance
  steps after the builder installs the build.

## Alternatives rejected

- Keep two servers and only shorten the docs: still two entries per host and
  two processes; the user asked for one.
- Make `app mcp` itself serve Case tools: silently changes what existing
  `app mcp` hosts see and duplicates the Case tools next to their `case`
  entry. A new name lets hosts move when they choose.
- Merge the authorization paths (let a harness access Yes cover Case, or a
  Case registration cover meetings): weakens both; rejected by the 2026-11-20
  harness access decision as well.
- Keep Connect writing `case` pointing at `whytap mcp`: hosts that also add
  the README's `whytap` line would carry two full copies of every tool.
- Remove `whytap` on Disconnect: removes application controls the person may
  have set up themselves (see Why).
- Remove `app mcp` / `case mcp`: breaks configured agents for no gain.

## Consequences

A host configured with the older two entries keeps working; it shows Case
tools twice only if it also adds `whytap mcp`. The built-in OpenCode agent's
`case mcp` command is unchanged. Like `app mcp`, the unified server answers
tool calls concurrently and drops the reply of a call still running at EOF;
interactive hosts keep stdin open, so only piped one-shot scripts notice.

Implementation: `feature/one-whytap-mcp`, PR to be linked by the builder's
merge.

## Supersedes / superseded by

Supersedes the two-server packaging described in
[the app-control plugin decision](2026-10-21-app-control-plugin.md) and the
`case`-entry command in [Case Connect offers Claude Code
again](2026-10-21-case-connect-claude-code.md). Their authorization rules are
unchanged.
