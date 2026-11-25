---
id: helper-follows-new-build-2026-11-25
type: decision
title: A running Whytap MCP helper replaces itself with the new build after an update
summary: When the app denies a long-lived `whytap mcp`, `app mcp` or `case mcp` as a stale helper and the helper file on disk is a different build that strictly validates against the running helper's own designated requirement, the helper `execve`s that file in place (same pid, parent and stdio), carries the MCP handshake and every unanswered request over, and the new image answers them. The app's trust check is unchanged.
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
- **Identity.** At start, off the handshake path, the helper records the
  designated requirement of its own file, but only while that file still is the
  running code: strict whole-file validation of every architecture passes and
  the kernel's cdhash of this process (`csops(CS_OPS_CDHASH)`) is among the
  file's cdhashes. A replacement must pass strict whole-file validation against
  that requirement (for the installed app: identifier `whytap`, Developer ID
  team `UVBKCN5PPV`) and have different cdhashes. A failed whole-file check is
  final; slices are only hashed after it passed (a Rosetta process runs the
  x86_64 slice). Without a baseline nothing is a replacement. An ad-hoc helper's
  requirement is its own cdhash, so it never follows another build.
- **Trigger.** A `.denied(.untrustedHelper)` answer requests a handover only
  when such a replacement is on disk and the loop budget allows it (at most
  three relaunches per process within 120 seconds; the history survives exec).
  Otherwise the call is answered as before.
- **Waiting.** Denied calls are held (no reply). Each call leaves the pending
  set and becomes answered or held in one step under the server's gate, so a
  cancellation always finds it. Later lines wait (at most 256 lines / 8 MB,
  beyond which the handover is abandoned and everything is answered here);
  cancellations still reach calls in flight, and a held call its client
  cancels is dropped. The exec happens once nothing is in flight.
- **Exec, bound to the verified file.** Right before `execve` the file is
  verified again. The carried bytes (held calls, waiting lines, unread stdin)
  drop every request whose cancellation is already among them. The envelope
  carries those bytes, the handshake state and the verified cdhashes through an
  unlinked temporary file whose descriptor survives exec
  (`WHYTAP_MCP_RESUME_V1_FD`). The writer refuses an envelope above the bound the
  reader accepts (16 MB) and any file it could not unlink first; then the old
  image answers everything itself. The new image resumes only if the code it
  runs is one of the verified cdhashes; otherwise each carried request gets an
  explicit JSON-RPC error and nothing is replayed.
- **Rollback.** A replacement whose file lacks the versioned key cannot resume
  the envelope. The old image waits for a half-written request to complete,
  answers every carried request with an explicit "retry" error, and then execs
  it without state; that build serves the following calls.
- **Access probe.** It is carried as done only once the app answered it. A
  probe still in flight at exec is closed with the process (broker sockets are
  close-on-exec) and the new image probes once more; a stored answer means no
  second card.
- MCP modes read stdin with `FileDescriptorLineSource` instead of stdio: stdio's
  read-ahead buffer would vanish on exec. `read()` happens only under the lock
  the handover takes, so no byte is lost between the two images. An
  unterminated frame keeps at most 512 KB + 1 byte; the server answers it as too
  large.
- A failed `execve` disables the handover for that process and every held call
  gets its old answer.

## Why

- **The check stays exactly as strict.** After exec the process runs the new
  file, so it passes the same audit-token and cdhash check as a helper the
  harness had just started. Nothing in the app changed and nothing is trusted
  by path. The helper itself executes only a file that is signed by the same
  signer it was launched with and validates in full.
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
- **Every request gets an answer.** Resumed, refused with an explicit error, or
  answered by the old image: no path leaves a request silent, including a
  rollback build and a file that changed between verification and exec.
- **Reactive, not polling.** The first call after an update pays one denied
  round trip and the exec (milliseconds). No timer and no file watching.
- **Running cdhash and signer from the right source.** Checked live on
  2026-11-25: for `SecCodeCopySelf`, Security's signing information is read
  from the file at the process's path, which after an update is already the new
  build. So the running cdhash comes from the kernel, and the signer is read
  from the file only while its cdhash matches the kernel's.
- **The resume file grants nothing.** Whoever can set the helper's environment
  can also write its stdin; the state holds only request bytes, two handshake
  flags and cdhashes the new image compares with its own.

## What was tested

- `HelperBuildHandoverTests` (23): an open client keeps working after the
  replacement, each call answered once by the new build and no second
  handshake or probe; a partial line read before the handover survives it;
  Whytap not running answers `unavailable` without relaunch; a file that does
  not verify is never executed and every call is answered; repeated
  replacements relaunch again, the fourth within two minutes is refused and
  carried calls are still answered, the budget returns after the window; a
  failed exec answers held and later calls; the handover waits for a call the
  app is still answering and replays only the denied one; a call cancelled
  during the handover, or whose cancellation is already buffered, is never
  dispatched; a stale access probe and a probe still in flight are repeated
  once; `case mcp` follows; a rollback build gets every carried request
  answered and waits for a half-written frame; the file is verified again
  right before exec; an envelope over the shared bound and too many waiting
  lines are answered here; an image that is not the verified replacement
  refuses carried requests; unterminated frames are bounded; the resume file
  is read only from an inherited regular file; without a baseline nothing is a
  replacement.
- `scripts/check-helper-follows-build.py` (live, real `execve`, 21 checks): a
  throwaway `Selftest.app`, a throwaway keychain (never in the search list)
  with two self-signed code-signing certificates, debug helpers that differ by
  LC_UUID, and a fake broker that trusts a peer only when the kernel's running
  cdhash equals the valid file's. Two atomic replacements: the same pid answers
  from the new build and runs its code; pipelined calls answered once; the
  broker always sees the harness as the parent; the fourth relaunch within two
  minutes is refused; an invalidly signed file, a valid file of another signer
  and a valid ad-hoc file are not executed (one denied request each); a
  rollback build without the protocol: explicit answer for the triggering call,
  same pid runs it and answers later calls; an ad-hoc helper never follows;
  `case mcp` and `app mcp` follow; without a broker the call answers
  `unavailable`; EOF exits.
- Builder review 565 (2026-11-25) found five gaps in the first revision, all
  fixed here: no signer requirement and a per-slice fallback after a failed
  whole-file check; a buffered cancellation and a pending-to-held gap; the
  probe carried as done when only scheduled; unbounded envelope and frames and
  an unchecked unlink; and a rollback build dropping the triggering call.
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
- Following ad-hoc builds: without a signer there is nothing to verify but the
  cdhash the app already trusts.

## Limits

- Helpers already running a build without this change cannot follow; they need
  one last reconnect after the first build that has it is installed.
- Source and community builds signed ad-hoc never follow; they keep needing a
  reconnect after an update.
- A file swapped between the final verification and `execve` runs anyway (it
  is what the harness would start next); it gets no carried request.

2026-11-25 · branch `fix/helper-follows-new-build`
