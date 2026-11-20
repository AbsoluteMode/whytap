---
id: whytap-settings-sync
type: decision
title: Settings and provider keys sync between Macs through the backup repository
summary: One encrypted document in the private backup repository, merged item by item with the later change winning, keeps preferences and provider keys the same on Macs sharing a recovery code.
status: confirmed
tags: [backup, github, sync, settings, keys, multi-mac]
canonical_for: [settings-sync]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user asked for Whytap data to stay the same on two Macs, accepted syncing through the private GitHub backup repository, and chose settings and provider keys as the first part.
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/Sync/SettingsSyncService.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/Sync/SettingsSyncModel.swift
    confirmed_at: 2026-11-20
related: [../project.md, 2026-10-20-backup-auto-sync.md, 2026-10-19-config-backup.md, 2026-10-19-api-and-models.md]
---

# Settings sync between Macs

## Context

Backups already carry every setting and key, but a second Mac only gets them
through Restore, a relaunch and a full replacement. The user wanted two Macs to
stay the same on their own, starting with settings and provider keys. Whytap has
no servers of its own, and the backup already has a private GitHub repository,
a recovery-code key and a Keychain token.

## Decision

- A switch, Settings -> Backup -> Sync settings between Macs, off by default.
- One document, sealed with the backup key (AES-GCM; the key ID is readable),
  at `whytap-sync/settings.v1.json` (`settings-beta.v1.json` for beta) in the
  existing private Exodia-Backup repository, through the Contents API.
- Reads are conditional (ETag, 304). Writes carry the blob SHA; a write that
  lost a race (409/422) re-reads, merges and retries, at most three attempts.
- Rounds run every minute and two seconds after a defaults change, only while
  the switch is on and no restore waits for relaunch.
- Items: the backup allowlist except per-Mac preferences (island display,
  calendar accounts, hidden feeds, Apple Calendar switch, routing repair copy),
  and the backup's provider key accounts except `calendar.*`.
- Each item merges alone. The later change wins; an exact tie goes to the
  greater device ID so both Macs agree. A removal is an entry without a value,
  so a deleted key is deleted on the other Mac instead of returning.
- Joining (turning the switch on, or the first launch after a restore): shared
  values replace this Mac's; items only this Mac has are uploaded. Previous
  values remain in the local settings history.
- A local ledger, `Application Support/<bundle id>/settings-sync/ledger.json`
  (0600, hashes only, not in backups), records what this Mac agreed and its
  random device ID. Turning sync off deletes it; a restore that included
  settings or keys deletes it.
- A round: note local edits in the ledger with the time they were seen,
  before any request; read the shared document; read local values again;
  save the new agreement; apply; upload. A Mac has joined once it takes an
  existing shared document; the first Mac, once its upload succeeds. Values a
  joining Mac already had are stamped at the epoch: they fill gaps but never
  replace a shared entry, whatever the device IDs (fifth review).
- Stores that keep their own copy reload after an applied change: routes,
  hotkeys, Toolbox layout, notification sounds, Brightness keys, island
  helpers, Drop mode, capability flags and idle hide.

## Why

The repository, key, token and privacy model already exist and were accepted
for backups; GitHub sees only ciphertext. The Contents API's SHA gives a real
compare-and-swap, which Releases do not. Per-item merging keeps both of two
unrelated edits; whole-document last-writer-wins would silently drop one.
Joining by taking the shared values matches what the user expects of a second
Mac and keeps an old restored backup from overriding newer choices.

Calendar accounts stay per Mac because each Mac rotates its own refresh token;
sharing one would sign the other Mac out. The display is a screen of one Mac.

## Safety

The first review (Codex) found that a key saved while GitHub answered could be
deleted by a removal from the other Mac, that a failed ledger write could turn
an applied removal into a local one and spread it, that offline edits took the
time they synced instead of the time they were made, that a 304 could reuse a
document opened with an old recovery code, and that a failed write could finish
a join. Each has a test now:

- Local values are read again after the shared document arrives.
- The agreement is saved before anything is applied, with each item to be
  written marked pending (old value plus target). Finding the old value later,
  after a crash or a refused Keychain write, means the write never landed: it
  is written again, never shared as a removal (second review).
- Edits are stamped when noticed (two seconds after a defaults change, within
  a minute for a key), on every sync request including during backoff, and
  saved before the network. Edits made while Whytap is not running are stamped
  at the next launch.
- A joining Mac records no removals: an item it drops before its first shared
  round never reaches the other Macs (second review).
- A round that started before the switch flipped reports nothing.
- While a round runs it is the only writer of the ledger; an edit noticed
  meanwhile keeps the time it was seen in memory and the next round, which
  runs at once, stamps it with that time (third and fourth reviews).
- A key received while joining and removed during a conflicting write stays
  removed: joining is complete once the shared document was taken (fourth
  review).
- A restore that will replace settings or keys leaves a marker before it
  starts. Applied, it forgets the agreement; rolled back or cancelled, it keeps
  it, so unsynced edits survive. A marker left by a crash after the restore
  finished counts as applied (fifth review).
- An edit seen during a write, then undone and made again, keeps the time of
  its last sighting (fifth review).
- Keys the shared document names are read even when this Mac's routes do not
  list them, so a key restored without its server meets the shared removal
  instead of being uploaded again later (third review).
- The cached document is bound to the key ID that opened it.
- Joining stays unfinished until the upload succeeds or nothing needed it.
- Turning the switch off or on, or a restore waiting for relaunch, stops a
  round before it applies, saves or uploads.
- A setting the other Mac removed stays removed when a store reloads and saves
  its default; only removals applied in that round are cleared again.
- Each write first checks that the repository is still private.
- The document is limited to 900 KB, below the Contents API's 1 MB inline limit.

- An unreadable Keychain item or defaults value stops the round. It never
  reads as a removal, so a locked Keychain cannot delete keys everywhere.
- Another recovery code is reported ("Your other Mac uses a different recovery
  code") and the shared file is never overwritten.
- Shared values this build rejects are not applied; this Mac's value replaces
  them. Items from a newer app pass through untouched. A newer format asks for
  an update.
- Failures back off from one to fifteen minutes and respect GitHub's rate
  limit time.
- Known gaps: a restore prepared while a write's privacy check is in flight
  can still let that one write finish (it shares current values, which the
  restore replaces only at relaunch); a repository made public between the
  check and the write receives that one ciphertext.
- Replacing the recovery code does not rewrite the shared document: the other
  Mac reports a different code. Earlier versions sealed with the old code stay
  in the repository's Git history, like backups under the old code.
- Syncing applies the user's own choices from their other Mac, which they
  enabled; it is not a silent route change. Nothing moves to a provider the user
  did not choose on one of their Macs.

## What was tested

Thirty-three tests with two simulated Macs sharing a fake repository: first upload
without the display and with ciphertext only; joining takes shared values and
uploads extras; edits to different items both survive; the later edit of one
item wins; a removed key is removed on the other Mac; an unreadable Keychain
stops the round; a lost write race merges and retries; another recovery code
never overwrites; no key asks for a backup; off and on rejoins; unknown and
invalid items are left alone; an unchanged round writes nothing; tampering and
newer formats are detected; the Contents API transport (404, 304, base64,
SHA conflict); routes, hotkeys and Toolbox reload; and one test per review
finding above (key saved during a read, offline edit time, new recovery code,
join losing a write race, refused Keychain write, quick off and on, an edit
during backoff, a key dropped before joining, a removal a store re-saves, a
key removed while the joining write is in flight, a restored key of a removed
server, a received key removed during a conflicting join write, an edit seen
during a write keeping its time, a pre-join value after a refused Keychain
write, a shortcut changed back and forth during a write, restore markers). The
fourth- and fifth-review tests were checked to fail with their fixes reverted. Timestamps are stored as
integer milliseconds after the first run showed Date round-off.

Not tested: two real Macs against GitHub, and every store reacting live.

## Rejected

- iCloud Drive folder: duplicates files on conflict and needs iCloud on both.
- Local network: both Macs must be on together.
- CloudKit: needs a container and new signing entitlements.
- Releases as transport: no conditional write, and a release per change.
- Whole-document last-writer-wins: drops one of two concurrent edits.
- Splitting the routing document per feature now: servers and keys depend on
  it; it stays one item for this first part.

## Later

To-do, Vocab beyond its preference, Case and meeting notes are later parts.

2026-11-20 · branch feature/settings-sync
