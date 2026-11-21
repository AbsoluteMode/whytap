---
id: whytap-backup-repository-name
type: decision
title: New GitHub backups go to Whytap-Backup; an existing Exodia-Backup stays in use
summary: Connect creates a private Whytap-Backup repository for new users, keeps using an existing Exodia-Backup (or the name GitHub reports after a rename), and remembers the choice per Mac.
status: confirmed
tags: [backup, github, naming, compatibility]
canonical_for: [backup-repository-name]
verified_at: 2026-11-21
sources:
  - type: user-confirmed
    reference: On 2026-11-21 the user asked to stop creating Exodia-Backup repositories and chose the option where new connections use Whytap-Backup while existing Exodia-Backup repositories keep working.
    confirmed_at: 2026-11-21
  - type: repository
    reference: Sources/Sidekey/Backup/GitHubBackupTransport.swift
    confirmed_at: 2026-11-21
related: [2026-10-19-whytap-name.md, 2026-10-20-simple-github-backup.md, 2026-11-20-settings-sync.md]
---

# Whytap-Backup for new GitHub backups

## Context

The product was renamed to Whytap, but Connect still created a private
repository named Exodia-Backup. The rename decision had kept that name as a
compatibility contract so existing backups stay reachable.

## Decision

- Connect first asks GitHub for `<owner>/Exodia-Backup`. If it exists, Whytap
  keeps using it, under the name GitHub reports: a repository the user renamed
  on GitHub (GitHub answers the old name) is used under its new name. Only the
  two names Whytap-Backup and Exodia-Backup are accepted.
- Without one, Connect uses `<owner>/Whytap-Backup`, creating it private if it
  does not exist.
- Reconnecting the same GitHub account keeps this Mac's saved repository when
  it still exists, even if the other name exists too; another account starts
  from the order above (builder review of PR #344). A saved repository the
  new token cannot see (GitHub answers 404 for a private repository outside a
  fine-grained token) is an access error: the destination and the previous
  token stay, nothing moves to the other name. A rename GitHub reports is
  followed. To choose another repository, Disconnect, then Connect.
- The chosen name is saved per Mac in `backup.github-repository.v1`. A
  connection saved before this key existed reads as Exodia-Backup, so existing
  Macs keep their destination without reconnecting. Disconnecting removes it.
- Backups, restore and settings sync use the saved name. Release tags
  (`exodia-backup-…`), the archive marker and formats are unchanged.

## Why

New users see the product's name. Existing users lose nothing: a new Mac that
connects finds the old repository first, so Restore still reaches every earlier
backup, and nothing is renamed or moved on GitHub by the app.

## What was tested

Transport tests: a new user gets a private Whytap-Backup (checked request
order: user, old name, new name, create, recheck); an existing Exodia-Backup is
kept with only GET requests; reconnecting the same account keeps a saved
Whytap-Backup while Exodia-Backup also exists (also through BackupViewModel,
the builder's scenario, which fails without the fix), another account's choice
does not carry over; a replacement token that cannot see the saved
repository gets an access error and keeps the destination and token (the
builder's second scenario, which fails without the fix); a rename of the saved
repository is followed; a repository renamed on GitHub is followed; only
the two names are accepted, and a missing saved name means Exodia-Backup. All
backup and settings sync tests pass.

## Rejected

- Renaming existing repositories from the app: needs administration rights on
  the token, and older Whytap copies on other Macs would lose the destination.
- Keeping Exodia-Backup for everyone: the user asked for the Whytap name.

2026-11-21 · branch feature/whytap-backup-repo
