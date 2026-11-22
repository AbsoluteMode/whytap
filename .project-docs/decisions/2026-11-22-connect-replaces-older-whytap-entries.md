---
id: connect-replaces-older-whytap-entries
type: decision
title: Connect replaces MCP entries that earlier Whytap versions wrote
summary: Connect (Settings -> Case and onboarding's Coding agents) now treats a plain entry running `mcp`, `app mcp` or `case mcp` on this app's helper, or on the same flavor's Exodia-era install path, as Whytap's own; it replaces such a `whytap` entry with `<helper> mcp` and removes such a `case` entry. Every other entry is still "Configured manually" and stays.
status: confirmed
tags: [agents, mcp, case, connect, onboarding]
canonical_for: [connect-earlier-whytap-entries]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 Maxim connected Claude Code and Codex from the 1701 build. Codex got `whytap` -> `…/Helpers/whytap mcp`; Claude Code showed "Configured manually — Whytap left it as is" because `claude mcp list` still held `whytap` -> `/Applications/Whytap.app/Contents/Helpers/whytap app mcp` and `case` -> `… case mcp` from earlier builds. Maxim approved the fix through the orchestrator session.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Case/Clients/CaseClientConnector.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/Case/CaseConnectMatrixTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-21-one-whytap-mcp-server.md, 2026-10-21-case-connect-claude-code.md]
---

## Context

The one-server decision (2026-11-21) let Connect change only the exact
canonical entry. That closed a class of builder findings, but it also left
every person who used Whytap before it with a broken Connect: the plugin, the
README line and older Connect builds wrote `whytap` -> `<helper> app mcp`
and `case` -> `<helper> case mcp`. Connect called those "Configured manually"
and changed nothing, so the host kept two servers and Case tools twice.

## Decision

- **An earlier Whytap entry** is a plain entry (the same shape test as the
  canonical one: command and arguments only; for JSON hosts `type: "stdio"`
  and an empty `env` are allowed; for Codex every other field of
  `codex mcp get --json` is unset) whose command is
  - this app's helper path as written, or
  - the same flavor's helper at its Exodia-era path, only when this app runs
    from the standard install path (`/Applications/Whytap.app` adopts
    `/Applications/Exodia.app/Contents/Helpers/whytap`;
    `/Applications/Whytap-Beta.app` adopts
    `/Applications/Exodia-Beta.app/Contents/Helpers/whytap`),

  and whose arguments are exactly `mcp`, `app mcp` or `case mcp`
  (`WhytapMCPEntry.earlierArguments`, `ownHelperPaths`).
- **Connect** (one code path: `CaseClientSetup.connect`, used by Settings ->
  Case -> Connect, Retry agent setup and onboarding's Coding agents):
  - canonical `whytap`: nothing to add;
  - absent `whytap`: add `<helper> mcp`;
  - earlier Whytap `whytap`: replace it with `<helper> mcp`;
    - Codex: `codex mcp add` replaces the name in one write;
    - Cursor: the key is rewritten in the same atomic write that removes `case`;
    - Claude Code: `claude mcp remove -s user whytap`, then `add` (its CLI
      refuses an existing name). If the add fails, the earlier entry is added
      back with its own command and arguments, which is exact because it was
      plain and carries no value. If the remove fails, nothing else runs;
  - any other `whytap`: "Configured manually — Whytap left it as is", no change,
    `case` kept;
  - then a `case` entry that is an earlier Whytap entry is removed, best
    effort. A `case` with the person's own settings stays.
- **Disconnect** removes a `case` entry by the same test and never `whytap`.
- **Beta, dev and moved builds.** The beta app never adopts the prod app's
  entries and the prod app never adopts beta's: they are different apps with
  their own bundle ID, keychain service and broker socket, so moving an entry
  across would point a host at the other app's Case. A dev build or a copy
  outside `/Applications` owns only its own exact path: a Connect from a dev
  build must not move the person's working entry for the installed app onto a
  build folder.
- OpenCode has no config file to change: Whytap's own OpenCode gets the
  `case mcp` command in memory (`CaseBuiltInAgentAccess`).

## Why

- The entries in question are provably Whytap's: the exact helper path of
  this app (or the path Sparkle kept for the same app before the rename), a
  subcommand only Whytap's helper has, and nothing a person would add. Leaving
  them made the most common existing setup report "Configured manually".
- The test stays a shape test, not a parser of intentions: a single extra
  field, argument, env value, disabled flag or filter still makes the entry
  the person's. The builder findings of 2026-11-21 (escapes, look-alike
  paths, values on a restore command line, dropped timeouts, empty
  allowlists, a disabled entry losing its `case`) all stay closed: the
  replaced entries have none of these by definition, and the Claude Code
  restore command carries only a path and the subcommand words.
- Replacing `case mcp` or `app mcp` with `mcp` loses nothing: `whytap mcp`
  serves both tool sets, and each Case call is still the same broker request.

## What was tested

- `CaseConnectMatrixTests` (fake CLIs and real temporary JSON files) for
  Claude Code, Codex and Cursor:
  - `whytap` `app mcp` + `case` `case mcp` -> remove/add `whytap`, remove
    `case` (Claude), one `codex mcp add` + remove `case`, one Cursor write
    with only `whytap` -> `mcp`;
  - only `whytap` `app mcp` -> replaced; Claude's own written form
    (`type`, empty `env`), `case mcp` under `whytap` and the Exodia path too;
  - `case` with an env value -> `whytap` replaced, `case` left byte for byte;
  - `app mcp` with env, disabled, an extra argument, `app status`, the beta
    helper and a dev build's helper under the prod app -> "Configured
    manually", nothing changed, `case` kept;
  - the prod entry under the beta app and under a dev build -> manual; the
    Exodia-Beta entry under the beta app -> replaced;
  - a second Connect: no changing command, Cursor's file and modification
    date unchanged;
  - Claude add failure -> the earlier entry is added back, `case` kept;
    remove failure -> nothing else runs;
  - Disconnect never touches any `whytap` form.
- `CodexCLIConfigReadingTests.test_real_codex_replaces_earlier_whytap_entries`
  runs the installed Codex CLI on a temporary HOME: `app mcp` + `case`
  become one `whytap` -> `mcp`, `case` absent, an unrelated server kept, and
  a second Connect runs no changing command and leaves `config.toml` byte
  for byte.

## Alternatives rejected

- Keep "Configured manually" and tell people to remove the entries: the
  setup Whytap itself created would be reported as the person's own.
- Treat any entry whose command ends in `Helpers/whytap` as ours: a moved,
  beta or dev Whytap and look-alike paths would be rewritten.
- Adopt the prod entry from a beta or dev build: it would repoint a working
  host at another app's broker.
- `claude mcp add-json` to replace in one step: it puts the entry on a
  command line, the problem the 2026-11-21 reviews removed.

## Consequences

- Maxim's Claude Code, with `whytap` -> `app mcp` and `case` -> `case mcp`
  from earlier builds, ends with one `whytap` -> `mcp` after Connect.
- A host whose entries point at an install path not listed here still reports
  "Configured manually"; the person removes the entry once.

Merged through the PR that introduced this file.
