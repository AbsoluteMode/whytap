---
id: todo-locked-screen-2026-11-04
type: decision
title: The To-do archive stays readable while the screen is locked
summary: PlannerStore and the helper save planner-v1.json with the system default protection class (CompleteUntilFirstUserAuthentication) instead of CompleteUnlessOpen, and any successful read moves an older file to that class, so agents can read and edit To-do on a locked Mac.
status: confirmed
tags: [planner, todo, agents, helper, data-protection]
canonical_for: [todo-locked-screen]
verified_at: 2026-11-04
sources:
  - type: user-confirmed
    reference: On 2026-11-04 the user approved making agents work with To-do while the Mac is locked, after `whytap todo list` failed on a locked screen.
    confirmed_at: 2026-11-04
  - type: repository
    reference: Sources/WhytapCaseKit/PlannerTodoFile.swift
    confirmed_at: 2026-11-04
  - type: repository
    reference: Sources/Sidekey/Planner/PlannerStore.swift
    confirmed_at: 2026-11-04
  - type: repository
    reference: Tests/SidekeyTests/Planner/PlannerExternalChangesTests.swift
    confirmed_at: 2026-11-04
  - type: repository
    reference: Tests/WhytapCaseKitTests/TodoCommandTests.swift
    confirmed_at: 2026-11-04
related: [2026-11-03-todo-helper.md, 2026-11-03-todo-tree.md, 2026-10-19-planner.md]
---

# To-do on a locked screen

## Context

On 2026-11-03, with the Mac's screen locked (IOConsoleLocked), the running
Whytap 2.2.22 answered `whytap todo list` with `planner_unreadable`. The
archive was intact, but opening `planner-v1.json` failed with EPERM for every
process, including an unsandboxed shell; the lock file next to it opened
normally. PlannerStore had saved the archive with
`.completeFileProtectionUnlessOpen` since the Planner was introduced, without a
recorded reason. Under that class a file can only be opened while the Mac is
unlocked. Every other Whytap file, including archives written by the helper,
used the system default class, CompleteUntilFirstUserAuthentication. The result
was that agents could not read or add To-do tasks while the user was away, and
the protection class changed with whichever side last saved.

## Decision

- `PlannerTodoFile.writeOptions` is
  `[.atomic, .completeFileProtectionUntilFirstUserAuthentication]`, used by
  both the app's PlannerStore writer and the helper's file path. The file is
  readable after the first unlock since startup, also while the screen is
  locked.
- `PlannerTodoFile.relaxProtection(at:)` runs after every successful read in
  PlannerStore and in the helper. A file with Complete or CompleteUnlessOpen
  (saved by builds up to 2.2.22) moves to the class above. A successful read
  means the Mac is unlocked, so the migration needs no unlock of its own.
- A store whose load failed (for example, it launched on a locked screen
  before migration) already recovers on the next To-do opening, app-control
  request or folder change through `refreshFromDisk`.

## Why

The user wants agents to fill To-do from a call while they are away, which
often means a locked screen. The stricter class protected only against reads
by processes running as the same user while the screen is locked. Those
processes can already read the rest of Application Support (meeting notes,
History), so it did not add a meaningful boundary. FileVault and the first
unlock after startup still protect the file at rest.

## Tested

- `testStoreKeepsArchiveReadableWhileTheScreenIsLocked`: an app save writes
  CompleteUntilFirstUserAuthentication, and a CompleteUnlessOpen file (as an
  earlier build left it) is migrated when a new store loads it.
- `testHelperMovesArchiveToTheLockedScreenReadableClass`: the helper's
  `todo list` migrates an old file, and a helper save keeps the class.
- A manual check on macOS (Darwin 27) showed that `FileManager.setAttributes`
  changes the class of an existing file, and that files written without an
  option already get CompleteUntilFirstUserAuthentication.
- Not tested here: an actual locked-screen read by the installed app. Locking
  the screen cannot be automated in tests.

## Rejected

- Serving `todo list` from memory and queuing adds while locked. This is more
  state and new failure modes, and the helper's file path would still be
  locked out.
- No protection option at all. The result would match the system default, but
  the class would be implicit and could change silently.
- Keeping CompleteUnlessOpen and telling users to unlock. That contradicts the
  requested unattended agent workflow.

2026-11-04 · branch claude/todo-locked-screen
