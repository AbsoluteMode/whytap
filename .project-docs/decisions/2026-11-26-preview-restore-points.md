---
id: preview-restore-points-2026-11-26
type: decision
title: Restore points around preview builds let previews change settings and stores code
summary: Before a preview build replaces the owner's app, the outgoing verified app saves an encrypted local restore point of his settings and local data (never provider keys, Case, History or meeting audio). A rollback the owner asks for reinstalls the verified app and applies it through the existing restore transaction, which keeps the replaced data as a recovery checkpoint. With that in place the build queue previews settings and stores changes too; what a restore point cannot undo still goes to normal validation.
status: confirmed
tags: [backup, restore, preview, build-queue, settings, admission]
canonical_for: [preview-restore-points]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the owner decided that the app itself should back up the settings he changed, so that previews may touch settings and stores (orchestrator task 42, spec REV 6, translated).
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Backup/PreviewRestorePoints.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Backup/ArtifactBackupEngine.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Sources/Sidekey/Backup/BackupViewModel.swift
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

The build queue installs some pull requests in the owner's app for his check
before review and the full suite (the preview lane). Until now a preview was
admitted only when it could not reach stored state at all: no settings, no
stores, no files. That admitted 1 of the last 40 and 5 of the last 100 main
commits, because almost every feature reads or writes a setting. The owner
decided the app itself should keep backups of what he changed, so a bad
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
  `list`, only while Whytap is quit, and prints one JSON object. A restore
  point is an archive of the engine's format with the sections settings,
  meetings, history (Costs), workspace and planner, encrypted with its own
  local Keychain key, stored under the app's Application Support folder in
  `restore-points/`. The last 5 are kept; creation needs the largest
  existing restore point plus 2 GB free. Nothing leaves this Mac.
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

- Unit tests: a restore point carries data but never keys or Case; a
  rollback restores a setting and agent instructions, keeps a key rotated
  during the preview and leaves a recovery checkpoint; chosen sections only;
  pruning to 5 and a clean refusal on low space; the command line refuses
  while Whytap runs and reports JSON.
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
  a button colour should not move his data.
- A restore point made by the preview build at its first launch: the code
  under test would protect itself.
- Including History and meeting audio: large, slow and outside the existing
  backup scope.
- Judging only the changed lines: a changed line may call anything else in
  the file, so a changed Swift file is judged whole.

2026-11-26 · orchestrator task 42 (REV 6)
