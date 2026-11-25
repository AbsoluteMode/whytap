---
id: helper-follows-new-build-2026-11-25
type: decision
title: A running Whytap MCP helper replaces itself with the new build after an update
summary: When the app denies a long-lived `whytap mcp`, `app mcp` or `case mcp` as a stale helper and a different, validly signed helper is on disk, the helper `execve`s that file in place (same pid, parent and stdio), carries the MCP handshake and every unanswered request over, and the new image answers them. The app's trust check is unchanged.
status: confirmed
tags: [agents, plugin, mcp, case, helper, updates]
canonical_for: [helper-follows-new-build]
verified_at: 2026-11-25
sources:
  - type: user-confirmed
    reference: On 2026-11-25 Maxim approved ("yes, do it") the orchestrator's proposal (ORCH-TASK 113) that a running helper, noticing a new build, switch to it by itself, after every installed build left the open Claude Code and Codex sessions with `unavailable` Whytap tools until `/mcp` or a new session.
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/WhytapCaseKit/HelperBuildHandover.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/WhytapCaseKit/MCPLineSource.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/WhytapCaseKit/AppControlMCPServer.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/WhytapCLI/main.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: scripts/check-helper-follows-build.py
    confirmed_at: 2026-11-25
related: [2026-11-21-one-whytap-mcp-server.md, 2026-11-20-harness-access.md]
---

# The MCP helper follows a new Whytap build

## Context

On 2026-11-25 Whytap 1757 started at 15:13:55. Every `Helpers/whytap mcp` and
`whytap app mcp` process started earlier (11:00, 13:01, ...) answered each tool
call with "Application controls are unavailable. Check that the helper belongs
to the running Whytap build."; helpers started after 15:13 worked. The builder
installs several builds a day, so the user kept reconnecting MCP (`/mcp`) or
opening new sessions, and agents read Whytap's files directly instead.

The cause is the broker's check, which is correct: the app trusts a peer only
when the code it runs has the cdhash of the validly signed helper bundled with
the app (`CaseSystemProcessInspector.isTrustedHelper`). The update replaces
that file; the old process still runs the old code, so every request it sends
is answered `.denied(.untrustedHelper)` before the app reads a byte of it.

## Decision

- The long-lived helper modes (`whytap mcp`, `whytap app mcp`,
  `whytap app screen-mcp`, `whytap case mcp`) wrap their broker clients in
  `BuildFollowingBrokerClient`. One-shot commands start from the current file
  anyway and are unchanged.
- A `.denied(.untrustedHelper)` answer starts a handover only when the helper
  file on disk is a different, valid build: its cdhashes (whole file with all
  architectures, and each valid slice, like the broker) do not include the
  cdhash the kernel holds for this process (`csops(CS_OPS_CDHASH)`). A missing,
  unsigned or invalid file never counts; the call is answered as before.
- The server then holds back the denied calls (no reply), defers new lines,
  still forwards cancellations to calls in flight, and drops a held call its
  client cancels. When no call is in flight it `execve`s the same path with the
  same argv. The handshake state (`initialized`, whether the access probe ran)
  and every unanswered byte (held calls, deferred lines, unread stdin) go to the
  new image through an unlinked temporary file whose descriptor survives exec
  (`WHYTAP_MCP_RESUME_FD`, removed from the environment on start, accepted
  only as an inherited regular file). The new image processes those bytes first
  and answers each call exactly once.
- MCP modes read stdin with `FileDescriptorLineSource` instead of stdio: stdio's
  read-ahead buffer would vanish on exec. `read()` happens only under the lock
  the handover takes, so no byte is lost between the two images.
- Loops are bounded twice: after exec the running code is the file on disk, so
  another denial no longer counts as "new" unless the file changes again; and
  at most three relaunches per process within 120 seconds (the history
  survives exec). A failed `execve` disables the handover for that process and
  every held call gets its old answer.
- If the old image's access probe was the request denied as stale, the new
  image probes once more; otherwise it does not repeat it.

## Why

- **The check stays exactly as strict.** After exec the process runs the new
  file, so it passes the same audit-token and cdhash check as a helper the
  harness had just started. Nothing in the app changed, nothing is trusted by
  path, and a build that fails code-signing validation is never executed.
- **`execve`, not a relay child.** The harness-access answer belongs to the
  helper's direct parent (2026-11-20 decision), and Case resolves its caller
  from the helper's parent chain. A child helper relaying requests would have
  the old helper as its parent and lose the user's Yes and the Case
  registration. `execve` keeps the pid, the parent and the stdio pipes, so the
  harness sees the same server and the stored Yes keeps applying.
- **Replaying is safe.** The broker sends `.denied(.untrustedHelper)` before it
  reads the request, so a denied call changed nothing in the app. A call is
  replayed only if its every broker answer was that denial; a call any other
  answer (or an interrupted exchange) touched is answered by the old image.
  The handover waits for calls already in flight, such as a pending approval.
- **Reactive, not polling.** The first call after an update pays one denied
  round trip and the exec (milliseconds). No timer and no file watching.
- **Running cdhash from the kernel.** Checked live on 2026-11-25: for
  `SecCodeCopySelf`, Security's signing information is read from the file at the
  process's path, which after an update is already the new build, so it reports
  the new cdhash and hides the difference. `csops(getpid(), CS_OPS_CDHASH)`
  returns the cdhash of the code actually running.
- **The resume file grants nothing.** Whoever can set the helper's environment
  can also write its stdin; the state holds only request bytes and two
  handshake flags.

## What was tested

- `HelperBuildHandoverTests` (12): an open client keeps working after the
  replacement, each call answered once by the new build and no second
  handshake or probe; a partial line read before the handover survives it;
  Whytap not running answers `unavailable` without relaunch; a new build that
  fails verification is never executed and every call is answered; repeated
  replacements relaunch again, the fourth within two minutes is refused and
  carried calls are still answered, the budget returns after the window; a
  failed exec answers held and later calls; the handover waits for a call the
  app is still answering and replays only the denied one; a call cancelled
  during the handover is not replayed; a stale access probe is repeated once;
  `case mcp` follows; the resume file is read only from an inherited regular
  file and never from a pipe.
- `scripts/check-helper-follows-build.py` (live, real `execve`): a throwaway
  `Selftest.app` with an ad-hoc signed debug helper and a fake broker that
  trusts a peer only when the kernel's running cdhash equals the valid file's.
  Two atomic replacements in a row: the same pid answers the next call from
  the new build and runs the new code; two pipelined calls after a replacement
  get one answer each; the broker always sees the harness as the parent; a
  corrupted (invalidly signed) new file is not executed and costs one request;
  the fourth relaunch within two minutes is refused; `case mcp` and `app mcp`
  follow a replacement; with no broker the call answers `unavailable`; all
  servers exit on EOF. 16/16 passed.
- The first live run found that `SecCodeCopySelf` reports the file's cdhash
  (see Why); a first draft of the fake broker had the same blind spot with
  `codesign -d <pid>`, which reads the file too. Both now use the kernel value.
- Not tested: the installed `/Applications/Whytap.app` (feature sessions do not
  install or launch it) and a Rosetta helper.

## Rejected

- Relay through a fresh child helper: loses the harness identity (above).
- Relaxing the broker to accept an older helper of the same team or path:
  weakens the check this change must keep.
- Polling the helper file or its version in the background: costs work in
  every idle session and still needs the same exec.
- Exiting so the host restarts the server: Claude Code and Codex do not restart
  a stdio server that exits; the session would lose Whytap until `/mcp`.

## Limits

- Helpers already running a build without this change cannot follow; they need
  one last reconnect after the first build that has it is installed.
- A rollback to a build without this change execs into a helper that ignores
  the resume state: the carried calls then time out in the host. Rollbacks
  are rare and the next request works.
- If the bundle is mid-replacement when the helper execs (not an atomic swap),
  the kernel may refuse or kill the new image; the builder replaces the whole
  bundle atomically.

2026-11-25 · branch `fix/helper-follows-new-build`
