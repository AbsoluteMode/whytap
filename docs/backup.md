# Backup and recovery

Connect GitHub once in **Settings → Integrations → GitHub**. Use an existing
GitHub CLI login or an access token. Whytap checks or creates the private
**Exodia-Backup** repository. The connection status is also shown in Backup.
Connecting does not upload user data.

In **Settings → Backup**:

- **Back up** saves everything listed below, including stored provider keys,
  encrypts it locally and verifies the GitHub upload. Save the code shown after
  completion outside Whytap. The same code unlocks subsequent automatic backups.
  The first backup turns on automatic sync while Whytap is idle.
- **Automatic backup** (shown once a GitHub copy exists) pauses or resumes
  automatic sync. A pause survives restart and keeps every copy; **Back up**
  then saves one copy and leaves sync paused.
- **Restore backup** takes that code and prepares the newest complete GitHub
  backup, including all its settings, keys and data. Quit Whytap normally and
  open it again to apply it. Current data is kept for recovery.

On a new Mac, restore an existing GitHub backup before creating another one.
The recovery code selects its matching encrypted copies, even if a different
code has newer uploads in the same repository. Newest means the time the data
was captured, rather than the order in which offline copies reached GitHub.
Older copies obtain that date from their authenticated archive manifest.

There are no data-selection switches, code verification steps or confirmation
screens. Created GitHub backups synchronize automatically, including copies made
before automatic sync was introduced. Settings, keys and artifact metadata are
checked every minute, but a change only marks the backup as pending: each
automatic snapshot is a complete archive, so one is taken at most once an hour.
That hourly check runs while Whytap is running and idle and hashes a coherent
export by content, even if no file metadata changed. A matching hash creates no
archive or upload. Changed data produces a fresh encrypted local snapshot before
any network work. **Back up** is never delayed by this schedule.
Calendar refresh-token rotation alone does not create a version; the next real
snapshot carries the current authorization, as with local settings history.
Snapshots wait during recording or agent work, and need free disk space for one
more archive plus 10 GB (2 GB for **Back up**); otherwise Backup shows how much
space is needed and nothing is exported. Without a connection, the newest pending automatic snapshot replaces
superseded unprepared snapshots; a resumable upload and verified older copies
are retained. Connection failures do not prevent fresh local capture. Network
retries back off to at most once every fifteen minutes, or longer if GitHub
requests it. Starting without a network also retries the connection in the
background; opening Settings is not required. Account or repository
permission failures require reconnecting. An unsupported file or size limit is
retried at the next hourly snapshot; **Back up** retries sooner.
A deleted unfinished GitHub draft is recreated automatically after repository
access is checked, without a reconnect loop. An interrupted upload continues
from the parts already on GitHub, confirmed by GitHub's checksum without
downloading them again, and Backup shows "Uploading backup part N of M…". Backup shows **Backup
synced** only after verification with no detected changes or copies waiting
and after the recovery code has been presented,
and links directly to the repository's GitHub Releases. Pending, syncing, paused
and error states have their own labels. Existing folder destinations and local
encrypted settings history are retained internally.
This Mac keeps only what GitHub does not have yet or still needs: unsent
snapshots, a resumable upload, restore checkpoints and the newest uploaded
archive, which the next upload is computed against. Older uploaded archives are
removed after each upload and at launch; GitHub keeps every uploaded version and
nothing is deleted there automatically. Each upload adds only the files that
changed, except a complete copy after 32 changes in a row. If you delete local
archives yourself, Whytap forgets them and takes a fresh snapshot instead of
failing.
Startup removes interrupted temporary generations and unindexed transfer files,
while retaining indexed snapshots, resumable uploads and restore checkpoints.
An unreadable or explicitly parked catalog preserves its unknown archives.
A previously interrupted management operation can still be finished or stopped.
Restored recording jobs and executable connections stay paused until enabled.
If the first upload finishes after leaving this screen, **Save your recovery
code** remains visible on return. **Save recovery code** / **Show recovery code**
requires the Mac password or Touch ID. Repeating **Back up** never reveals an
existing code without authentication. Seeing the code does not prove it was
saved elsewhere; keep it outside this Mac.

Encryption happens before upload. The recovery code is independent of GitHub
and cannot be reset by GitHub or Whytap. macOS permissions stay machine-specific.
If the code is lost, the existing encrypted copies cannot be unlocked. A new Mac
keeps them rather than silently replacing them with another code. Starting fresh
requires removing those copies in GitHub yourself or using another GitHub account.
GitHub receives encrypted bytes and cannot read the backed-up secrets without
the recovery code.
A backup restores a saved version; it does not merge edits between Macs.
No Whytap account, backup server or GitHub Actions is used.

## Sync settings between Macs

**Sync settings between Macs** (off by default) keeps models, provider keys,
hotkeys, the Toolbox layout, vocabulary and other preferences the same on every
Mac that uses the same recovery code. Set it up once:

1. On the Mac whose settings you want everywhere, make a backup, then turn the
   switch on first. Its settings and keys become the synced ones.
2. On the other Mac, connect GitHub, choose **Restore backup** with the same
   recovery code, reopen Whytap and turn the switch on. Its own settings are
   replaced by the synced ones; keys only it has are added for both.

A change reaches the other Mac within about a minute while both are running,
without a relaunch. When both Macs change the same setting, the later change
wins; changes to different settings both stay. Removing a key removes it on the
other Mac too. A Mac that turns sync on after another takes the synced
settings; its earlier values remain in the local settings history.

The switch appears once this Mac has a backup recovery code: after its first
backup, or after restoring one. Without a backup there is nothing to sync with,
and nothing is uploaded.

Each Mac keeps its own island display and calendar accounts. To-do, Case and
meeting notes are not synced yet; they still travel with backups. Settings are
encrypted with the recovery code before upload, into the same private
repository (`whytap-sync/`). Turning sync off on one Mac stops it there and
leaves the other Macs and the synced copy unchanged.

## What is included

Planner tasks and local Whytap events have their own To-do & calendar section.
Calendar connection settings and saved OAuth credentials travel in the settings
and provider-key sections. Connected events are fetched again from their source
after recovery; external event caches are not backed up. Older archives preserve
calendar connections already on this Mac. A visible Planner or retained task
draft blocks restore, while ordinary backups can continue.

- API & Models routes for every feature, registered server addresses, languages,
  meeting preferences, hotkeys, vocabulary, Toolbox layout,
  display and feature settings, and agent preferences.
- Whytap's saved speech and text provider keys (including Anthropic and each
  registered custom server), and independently recoverable
  Case items and secrets.
- Meeting catalogs, notes and transcripts (text only).
- Recorded Costs history, including exact prices, estimates and unavailable-price
  entries. Restoring keeps spending recorded only on the target Mac, deduplicates
  request IDs and never replaces a reported price with an estimate. Older archives
  without Costs leave this Mac’s Costs history untouched.
- App-owned Monitor dashboards, notification configuration and working files,
  and the neutral agent workspace's persistent instructions.

Not included: meeting audio, including recordings kept after failed processing,
and the History feed (clipboard entries and images, recent dictations and agent
answers). Audio is debugging material that made every snapshot gigabytes, and
clipboard content can be copied again. Restoring a newer archive leaves this
Mac's recordings and History as they are. Archives made before 2026-10-21 still
restore them; their recordings arrive paused.

Case items are merged with the target Mac's vault and encrypted using that
Mac's own local vault key. Unrelated existing Case items are retained. When a
project or key name from the backup is already used by a different item on
this Mac, the restored one is renamed (`alpha (2)`, `DB_URL_2`); this Mac's
names stay as they are. Restoring also brings back the backup's Case app
registrations (which AI apps may ask for keys, Approve or Bypass) and adds
them without asking for Touch ID, including Bypass: an app registered with
Bypass in the backup can receive keys without a prompt after the restore.
Registrations this Mac already has keep their own settings and take priority
over imported registrations, including another ID for the same identity or a
broader imported executable path. Review them in
Case -> access after restoring a backup you did not make yourself. Imported
notification sources and monitoring connections stay disabled until reviewed.
Recordings from older archives are recovered without automatically resuming
another Mac's remote provider jobs.

External scripts, SSH keys, model-provider accounts and credentials managed by
other applications are not owned by Whytap and are not copied. Downloaded
models, binaries, caches, logs, obsolete project indexes and OS permissions are
not part of the portable workspace. Archives are bounded to 64 GiB in total,
8 GiB per file and 200,000 entries; a snapshot exceeding a bound is refused.
Imported directly executed notification workers may need their executable
permission and machine-specific paths reviewed before re-enabling a source.
Nested Monitor and notification folders explicitly marked as disposable caches
with a valid `CACHEDIR.TAG` are excluded, including tagged Python environments.
Their scripts, settings, dependency descriptors and working data outside those
folders remain included. Recreate cached dependencies on the restored Mac before
enabling a worker; the archive records this exclusion. A folder name such as
`venv` alone is never enough to omit its contents.

Workspace paths remain conservative: regular files and printable ASCII names
without spaces, colons, separators or a leading dot, with at most 120 bytes per
name and five nested directory levels. Unsupported names or links identify the relative path
in the error; they are never silently dropped. See the customization guides for
[notification workers](customization/notifications.md) and
[Monitor collectors](customization/dashboards.md).
Retained inactive configurations survive subsequent backup/restore cycles. If
an older active configuration and its inactive copy coexist, both are retained
under distinct inert names. Older archives' retained recording directories
(held manifests, repair checkpoints, nested original audio) restore as inert
recovery data; active provider job records never do. New archives use schema 4; older Whytap versions must
update before restoring them. This version still reads schemas 1–3.

A damaged or incomplete archive is refused before restore. Failed uploads
keep the local copy for retry. Existing copies are retained; the simplified
screen does not delete archives or rotate recovery keys.
