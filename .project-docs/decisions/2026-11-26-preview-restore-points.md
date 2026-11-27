---
id: preview-restore-points-2026-11-26
type: decision
title: Restore points around preview builds let previews change settings and stores code
summary: Before a preview build replaces the owner's app, the outgoing verified app (quit, holding the instance lease) saves a same-Mac, byte-exact restore point of the settings domain and the covered Application Support folders (never provider keys, Case, History or meeting audio). A rollback the owner asks for reinstalls the verified app and applies it verbatim through the startup restore transaction, which keeps the replaced data as a recovery checkpoint. With that in place the build queue previews settings and stores changes too; what a restore point cannot undo still goes to normal validation.
status: confirmed
tags: [backup, restore, preview, build-queue, settings, admission]
canonical_for: [preview-restore-points]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the owner chose the same-Mac restore mode for preview restore points after the queue review of ticket 639 showed the cross-Mac import cannot round-trip (orchestrator task 42).
    confirmed_at: 2026-11-26
  - type: user-confirmed
    reference: On 2026-11-26 the owner decided that the app itself should back up the settings the owner changed, so that previews may touch settings and stores (orchestrator task 42, spec REV 6, translated).
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Backup/PreviewRestorePoints.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Backup/LocalRestoreSnapshot.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Backup/ArtifactBackupRestore.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Backup/ArtifactBackupEngine.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/Backup/PreviewRestorePointsTests.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: scripts/build-queue.py
    confirmed_at: 2026-11-26
related: [2026-10-19-config-backup.md]
---

## Context

The build queue installs some pull requests in the owner's app for a check by the owner
before review and the full suite (the preview lane). Until now a preview was
admitted only when it could not reach stored state at all: no settings, no
stores, no files. That admitted 1 of the last 40 and 5 of the last 100 main
commits, because almost every feature reads or writes a setting. The owner
decided the app itself should keep backups of what the owner changed, so a bad
preview can be undone and previews may touch settings and stores.

What already existed (Sources/Sidekey/Backup):

- Settings history: every change of the app's preferences (debounced) is
  saved as an encrypted local version, together with the provider keys the
  settings name; the last 300 versions are kept. It runs whether or not the
  Backup feature is turned on, and Settings → Backup can restore a version.
- Full backup archives (`ArtifactBackupEngine`) when Backup is on: sections
  settings, provider keys, Case, meeting notes text, Costs, dashboards and
  agent instructions (workspace), To-do and calendar (planner). Not the
  dictation History database and not meeting audio. Archives are encrypted
  with the user's key, kept locally and optionally copied to a private GitHub
  repository.
- Restore is a file-level transaction: a verified archive is staged, the next
  launch applies it before the app delegate opens any store, and the replaced
  files are kept as a recovery checkpoint.

## Decision

- `PreviewRestorePoints`: the app's own executable runs headless with
  `--restore-point create --reason <text>`, `apply <id> [--sections a,b]` or
  `list` and prints one JSON object. Exit codes: 0 done, 1 failed, 2 usage,
  3 Whytap or another restore point command is running.
- A restore point is a same-Mac `LocalRestoreSnapshot`, a separate, clearly
  named path from the cross-Mac backup import:
  - the whole settings domain as `preferences.plist` (no allowlist), except the
    preserved prefixes `backup.` (backup and settings-sync bookkeeping) and
    `SU` (updater state), which a rollback never changes;
  - APFS clone copies of the covered Application Support folders: drop
    learning (settings); meeting notes and meeting spaces (meetings); the
    planner folder (planner); Monitor, notifications, agent, project agents
    and projects (workspace); the Costs database and its companions (history);
  - a manifest with every directory, file (SHA-256, permission bits) and
    symbolic link (target), and which roots existed at capture.
  Provider keys (Keychain), the Case vault, Harness access, History, meeting
  audio, models and backups are never in it.
- Store: `<bundle root>/restore-points/<id>/` (0700) with `record.json`
  (0600) and the snapshot. A point is published by renaming its finished
  `.incoming-<id>` folder, so the record and the snapshot appear together;
  unpublished leftovers are removed. A record is a restore point only when its
  folder name is its ID and its numbers and sections are in range. The last 5
  are kept plus the one a parked restore points at; creation needs the size
  of the covered roots plus 2 GB free.
- Create and apply hold, for their whole run, the same advisory instance
  lease every Whytap flavor (production and beta) takes at launch, and refuse
  while a production or beta copy is running. `list` is read-only and may run
  beside Whytap.
- `apply` verifies the snapshot whole and parks it with
  `ArtifactRestoreTransaction.armLocal`. It never displaces another restore: a
  parked plan, an unfinished apply or a failed restore's preserved records make
  it refuse. The next launch applies it through the same transaction as a
  backup import (sealed before-state, journal, checkpoint move-aside, rollback
  on failure, recovery checkpoint), but installs the snapshot verbatim: nothing
  parked, filtered or rewritten, permission bits and links kept, files a
  preview created removed, roots absent at capture removed. Costs merge the
  rows written while the preview ran, because that spending really happened.
- There is no restore point key. The snapshot is a local plaintext-equivalent
  copy protected by 0700/0600 like the live data it copies, so no key can be
  lost or silently regenerated. The transaction's own before-state key keeps
  its existing fail-closed handling (retry on a locked Keychain, preserve the
  records, never discard).
- Info.plist declares `ExodiaRestorePointVersion` = 1. The build queue widens
  admission only when the installed app declares it.
- Before a restore-point preview replaces the app, the preview session quits
  the app, runs the outgoing app's `--restore-point create` and records the
  ID on the ticket (`preview-restore-point`; the record must come from the
  installed build within the last hour). A preview of that tier installed
  without one is never offered to the owner.
- Rollback with data happens only when the owner asks for it: the
  orchestrator relays `reject --restore-data [--sections ...]`. The next
  install (the app without the rejected PR) runs the new app's
  `--restore-point apply <id>` after the swap and before the launch; the
  launch applies it. A plain rejection only removes the code.
- Admission (`scripts/build-queue.py`): a preview is `plain` (touches no
  state, as before) or `restore_point` (settings and stores code, needs a
  restore-capable installed app). Both tiers exclude what a restore point
  cannot undo, by path and by any use in the old or new text of a changed
  Swift file, comments and string text aside:
  - provider keys, Keychain and Case: never in a restore point, and a
    rollback must never put older keys over current ones;
  - signing, entitlements, packaging and updates (Sparkle, appcast);
  - permissions and TCC (Accessibility, Post Event, microphone, event taps,
    login items, LaunchAgents);
  - the restore mechanism and startup (`Backup/`, `SidekeyAppMain`,
    installation guard, instance coordination, relaunch, build config) and
    the other binaries (CLI and MCP helper, Case kit);
  - data outside restore points (History database, meeting audio staging);
  - irreversible side effects: deleting or replacing files, processes and
    scripts, network requests (a sent message stays sent);
  - code loaded at run time and environment changes;
  - anything not a known kind of input (scripts, the queue itself, package
    manifests, plists), as before.

## Why

- A same-Mac rollback must give back exactly what this Mac had. The cross-Mac
  import deliberately makes a restored configuration inert (parked Monitor
  servers, disabled Notify sources, files written 0600, a preferences
  allowlist), so it cannot round-trip; the queue review of ticket 639 showed
  it. Reusing its transaction keeps one tested apply, checkpoint and rollback
  mechanism for both.
- Restore at file level survives schema migrations: a preview that migrates
  a database forward cannot be undone by running older code on it, but
  putting the older files back can.
- The outgoing app makes the restore point because it is the verified build
  that knows the current layout; the preview build is the one under test.
- Changes the owner made while the preview ran are not lost: the restore
  transaction keeps what it replaced as a recovery checkpoint, and the
  settings history keeps every settings version. That is why the rollback is
  an explicit request, not automatic on every rejection.
- Keys and Case stay out of restore points so a rollback cannot resurrect a
  rotated key; the same reason keeps credential code out of previews.
- History and meeting audio are large and outside the existing backup scope;
  code that writes them stays in normal validation instead of growing every
  restore point.

## What we tested

- Unit tests (`PreviewRestorePointsTests`), one per review class: a rollback
  puts back a preference outside the allowlist, an enabled Notify source, an
  active Monitor `servers.json`, an executable mode, a tagged cache, a
  symbolic link, removes a file and a folder the preview created, keeps
  `backup.` preferences and a key rotated during the preview, and leaves a
  recovery checkpoint; Costs keep spending made during the preview; chosen
  sections only; an interruption after the checkpoint, files or metadata
  rolls back to the preview state; a table of malformed commands is refused
  with nothing changed; create and apply need the lease, `list` does not; a
  parked or unfinished restore is never replaced; publication leaves no
  `.incoming` folder, modes are 0700/0600, records with out-of-range numbers,
  bad sections or another ID are ignored, a tampered snapshot is refused
  before anything is parked; pruning keeps 5 plus the parked one; low space
  is refused.
- Ticket 652 item 1: a dangling link occupies its path. Every restore target
  and rollback decision asks `ArtifactRestoreTransaction.entryExists` (lstat,
  never following a link): a dangling link inside a covered root goes to the
  checkpoint with the root, and a link at a covered root (created by the
  preview or replacing a captured root) makes the restore fail before
  committing, leaving the pre-apply state.
- Queue tests: the tiers, the exclusions (including a removed Keychain call,
  interpolated code inside a string, a fake video), the recorded restore
  point (unknown ID, a path instead of an ID, another build, too old, wrong
  actor), the refusal to offer an unprotected preview, and the relayed data
  rollback through the next install.
- Measured on the last first-parent commits of main (2026-11-26): the strict
  rule admits 2 of 40 and 4 of 100 (1 and 3 once the shared exclusions
  apply). With a restore-capable app both tiers admit 13 of 40 and 22 of 100.
  Most of the rest use credentials, the network, permission requests or
  file deletion somewhere in a changed file, or change other binaries or
  media kinds outside the list.

## Rejected

- Restoring automatically on every rejection: it would silently replace what
  the owner did meanwhile; the checkpoint still keeps it, but a rejection of
  a button colour should not move the owner's data.
- A restore point made by the preview build at its first launch: the code
  under test would protect itself.
- Including History and meeting audio: large, slow and outside the existing
  backup scope.
- Restore points through the cross-Mac backup import: it parks and filters
  on purpose, so a rollback would not return what this Mac had.
- An encrypted restore point with its own Keychain key: a lost key would make
  every restore point unusable or tempt a silent regeneration; the copy never
  leaves this Mac and the data it copies is not encrypted either.
- Judging only the changed lines: a changed line may call anything else in
  the file, so a changed Swift file is judged whole.

2026-11-26 · orchestrator task 42 (REV 6)
