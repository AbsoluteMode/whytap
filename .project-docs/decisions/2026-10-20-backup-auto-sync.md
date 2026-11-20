---
id: whytap-backup-auto-sync
type: decision
title: Created GitHub backups synchronize after changes
summary: Enable automatic synchronization after verified creation and show a compact truthful status with a direct GitHub backup link.
status: confirmed
tags: [backup, github, sync, recovery, ux]
canonical_for: [github-backup-auto-sync]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user requested that an existing backup synchronize after changes and that Backup use a short synchronized label with a GitHub link instead of its caption.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Backup/BackupViewModel.swift
    confirmed_at: 2026-10-20
related: [../project.md, 2026-10-20-simple-github-backup.md, 2026-10-21-backup-capture-pacing.md, 2026-11-20-settings-sync.md]
---

# Created backups synchronize automatically

## Context and decision

The simplified manual action previously left automatic scheduling disabled.
A verified successful Back up now enables synchronization. Existing GitHub copies
with a saved recovery credential and a recorded verified upload adopt sync once
at startup. A connection by itself, a failed first upload and a legacy folder
are insufficient. Maintenance stays paused, and later explicit cancellation or
disconnection keeps its existing pause behavior across restart.

Reuse the existing minute poll, two-minute attempt spacing, idle gate, encrypted
incremental transfers and retry records. The same recovery code remains valid;
background uploads do not reveal it. Check the artifact stamp again after upload
so changes during export or transfer remain pending.

## Status and link

Replace the connection caption and last-backup date with a compact status and
a GitHub link to the connected repository's Releases. The interface remains
English: “Backup synced”. Show it only with a checked connection, verified
upload, enabled sync, no detected changes, no pending copies and no active
operation, restore, maintenance or error. Waiting, syncing, paused, disconnected
and failure remain explicit. Keep actionable restore and error information.
The URL uses a validated GitHub owner and the existing backup repository name.

## Alternatives and rationale

Keeping manual-only backups fails the requested automatic protection. Showing
a permanent success label after any historical upload would hide pending changes.
Removing validation or restore errors would hide failed recovery. Reusing the
existing scheduler avoids a competing upload loop or credential format.

## Consequences and supersession

This supersedes the manual-only scheduling paragraph of the simple GitHub backup
decision. Encryption, verification, local retention and safe restore contracts
remain in force. Sync requires Whytap running and an idle opportunity; it is not
a multi-Mac merge. No new objection or unresolved product choice was supplied.

The two-minute capture spacing and "Choose Back up to resume" are superseded by
[backup capture pacing](2026-10-21-backup-capture-pacing.md): captures are at
most hourly and a visible Automatic backup switch owns pause and resume.
