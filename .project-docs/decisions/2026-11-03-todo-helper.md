---
id: todo-helper-2026-11-03
type: decision
title: Agents add To-do tasks through the bundled helper without restarting Whytap
summary: `whytap todo add|list` delivers batches to the running app over the authenticated helper socket, edits the planner file under a shared lock only when no app listens, and PlannerStore adopts external file changes instead of overwriting them.
status: confirmed
tags: [planner, todo, agents, helper, app-control]
canonical_for: [todo-helper]
verified_at: 2026-11-03
sources:
  - type: user-confirmed
    reference: On 2026-11-03 the user asked for a way to put a post-meeting task list into Whytap To-do from coding agents, without restarting the app or typing through Computer Use.
    confirmed_at: 2026-11-03
  - type: repository
    reference: Sources/WhytapCaseKit/PlannerTodoFile.swift
    confirmed_at: 2026-11-03
  - type: repository
    reference: Sources/WhytapCaseKit/TodoCommand.swift
    confirmed_at: 2026-11-03
  - type: repository
    reference: Sources/Sidekey/Planner/PlannerStore.swift
    confirmed_at: 2026-11-03
  - type: repository
    reference: Tests/SidekeyTests/Planner/PlannerExternalChangesTests.swift
    confirmed_at: 2026-11-03
  - type: repository
    reference: Tests/WhytapCaseKitTests/TodoCommandTests.swift
    confirmed_at: 2026-11-03
related: [2026-10-19-planner.md, 2026-10-20-todo-hover.md, 2026-10-21-app-control-plugin.md]
---

# To-do tasks from agents

## Context

To-do had no external input. PlannerStore read `planner-v1.json` once at
launch, kept the archive in memory and rewrote the whole file on every save,
so a script editing the file was invisible and then overwritten. Restarting
Whytap or typing through Computer Use were both unacceptable workarounds.

## Decision

- `Contents/Helpers/whytap todo add "<task>" …` (or `add -` reading one task
  per stdin line) and `whytap todo list [--all]` print one JSON object.
- With Whytap running, the helper sends `todo_add` / `todo_list` over the
  existing authenticated helper socket (app-control transport). The app saves
  through PlannerStore and answers from the saved state, which is the
  agent's confirmation (`delivery: "app"`, `added`, `existing`, task IDs).
- When nothing listens on that socket (connection refused, nothing sent), the
  helper does not launch Whytap. It edits the archive itself under an
  advisory lock (`planner-v1.json.lock`), keeps every other field, writes
  atomically and reads the file back before reporting `delivery: "file"`.
- PlannerStore takes the same lock for every save, adopts newer file contents
  first and then applies the user's change. The shared store also watches the
  Planner folder, so an external atomic save appears immediately; opening
  To-do re-reads the file as well.
- A batch is validated as a whole (1–100 titles, each 1–500 characters after
  joining inner line breaks with spaces); one bad title adds nothing. An
  active task with the same title is reported as `existing`, so retrying a
  delivered batch never duplicates it. Completed tasks do not block a title.
- PlannerStore.decodeArchive and the helper share one validator
  (`PlannerTodoFile.isValidArchive`: the app's field types, required keys and
  limits). The helper edits only archives the app loads and re-validates the
  edited bytes before replacing the file.
- An unreadable or unsupported file is never written by either side. The app
  keeps the last good list visible, blocks saves and recovers via Retry or a
  later valid file. A broken socket exchange is reported as `unconfirmed`
  and never falls back to the file, because the app may already have saved.

## Why

The helper socket already authenticates the bundled helper, needs no new
listener and is the only path with a real confirmation from the running
app. A deep link cannot report back (links only show places, Invariant 7) and
any web page can open one. A drop folder still needs the same merge logic and
gives no synchronous confirmation. Adopting external changes in PlannerStore
is required anyway so the closed-app path and any other local writer cannot
be silently lost.

To-do titles are user content, an exception to the app-control allowlist,
which otherwise excludes user content. The exposure is no wider than before:
any process able to run the helper as this user can already read and write the
user-private planner file.

Update, same day: the user expected any Claude on any of their Macs to find
this without repository instructions ("decompose the call into tasks"), so
`whytap app mcp` exposes `whytap_todo_add` / `whytap_todo_list`. They call
`TodoCommand.respond`, the same non-launching path and validation as the CLI,
never the launching app-control client. The server instructions mention the
local meeting-notes folder; the tools read no notes themselves.

## What was tested

Focused tests cover the running app (fake socket client and the real
AppControlController with a temporary store), the closed app (file path,
retry without duplicates, stdin batch), a file edit while the app runs
followed by a UI toggle, round-trip of existing tasks/events through the
helper's JSON edit, empty/too-long titles, an oversized request, a broken or
unsupported file, a broken socket exchange, valid JSON the app refuses (non-object events,
blank or long titles, a string `completedAt`, missing keys, unsafe meeting
links; app and helper must agree on each), an older running app that does
not know the operation, lock contention and the live folder watcher.
Not tested: the installed app with a physical helper call; that is acceptance
after the builder promotes this change.

## Rejected

- `whytap://tool/tasks/add?title=…`: links may not change data or report back.
- Launching Whytap from the helper to deliver: unexpected app start for a
  background agent; the locked file edit is enough and the app adopts it.
- Drop folder picked up by the app: same merge problem, no confirmation.
- Truncating long titles: silently changes the user's task; rejected instead.
- A `--note` field: tasks have no notes in the archive format.
