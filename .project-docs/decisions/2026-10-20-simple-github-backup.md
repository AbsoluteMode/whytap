---
id: whytap-simple-github-backup
type: decision
title: GitHub integration and complete backup in one action
summary: Connect GitHub in Integrations, show its checked state in Backup, and replace the setup and selection wizard with complete backup and code-based restore.
status: confirmed
tags: [backup, github, integrations, recovery, ux, recording]
canonical_for: [simple-github-backup]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user requested Integrations with GitHub, a GitHub connection checker in Backup, complete backups including all stored keys, code output for backup and code input for restore, without extra settings, explanations or confirmations, and a fix for the size error.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Backup/BackupViewModel.swift
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Backup/ArtifactBackupStaging.swift
    confirmed_at: 2026-10-20
related: [2026-10-20-backup-auto-sync.md, ../project.md, 2026-10-19-config-backup.md, 2026-10-19-backup-management.md, 2026-10-21-backup-resume-digest.md, 2026-10-21-backup-essentials-only.md, 2026-11-21-whytap-backup-repository.md]
---

# GitHub integration and simple complete backup

## Decision

Settings has an Integrations tab with GitHub. Connect reuses a GitHub CLI login
or accepts an access token and checks the private Exodia-Backup repository
(new connections: Whytap-Backup, see 2026-11-21-whytap-backup-repository.md).
It does not create a user-data backup or require an encryption code.
The existing token account, destination defaults and repository name remain
compatible; existing connected users do not have to migrate their backups.

Backup shows the checked GitHub state, a link to Integrations when disconnected,
and Back up / Restore backup. Actions require a valid connection. Opening either
page checks the existing repository without creating one. Revoked access or a
public repository disables the actions until reconnected.

Back up includes the entire supported workspace and every stored provider key.
It shows the recovery code after the encrypted upload and readback complete.
There is no section selection, scheduling switch, folder picker, paste-back
verification or confirmation. The code stays consistent for an existing key,
so every ordinary backup remains recoverable with the saved code. Copying uses
a transient concealed pasteboard item and suppresses local clipboard history.
Leaving Backup or closing Settings clears the displayed code.

Restore backup asks only for the code, downloads the newest complete version
from the connected repository, authenticates all contents and stages all included
sections. Existing stores remain open until normal quit; the transaction applies
at next launch and retains the before-state. There is no preview confirmation.
A short ready message explains the required ordinary restart. Restored executable
connections and recordings remain parked until explicitly enabled.

The later [automatic sync decision](2026-10-20-backup-auto-sync.md) supersedes
the original manual-only scheduling behavior: created GitHub backups now sync
automatically. Existing automatic
backup preferences, local encrypted history and legacy folder destinations are
preserved internally. Previously started maintenance has Finish / Stop recovery
actions so removing the old controls cannot trap an existing request.
This replaces the normal-screen setup and management UI described in the two
linked 2026-10-19 decisions; their encryption and transactional recovery rules
remain applicable.

## Size error

The recording stager had a separate 4096-file ceiling. The affected profile's
retained recording count exceeded it while its total bytes were far below the
archive limit. The error therefore described normal accumulated short chunks
as an oversized backup. Use the format's 200000-entry ceiling for retained
recording files; keep its 64 GiB total and 8 GiB per-file limits and full validation.
Tests use synthetic profiles only, including a 5220-file backup/restore round trip.
No user content or credentials are included in diagnostics or test artifacts.

## View-task lifetime

The combined render-enabled suite exposed a fixture teardown race: closing a
hidden NSHostingView did not finish its retained GitHub checker before the
injected URLSession was invalidated. A late checker then raised Foundation's
session-invalidated exception during a later suite. View-owned checks now
forward caller cancellation. Model shutdown rejects late operations and can
drain owned work; render teardown awaits that drain before invalidating its
network session or clearing the shared HTTP stub. Hidden hosting content is
explicitly detached on close. Regression checks cover late calls after shutdown
and cancelled view checks. Validation includes the full suite with backup
renders enabled, rather than disabling renders to avoid the race.
