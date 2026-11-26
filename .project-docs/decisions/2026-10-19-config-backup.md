---
id: exodia-user-artifact-backup-research
type: decision
title: Encrypted user artifact backup and recovery
summary: Separate encrypted backup storage from recovery credentials, cover Case and managed attachments, and prove restoration without the original Mac.
status: observed
tags: [backup, recovery, user-data, case, keychain, github, attachments, ux]
canonical_for: [user-artifact-backup]
verified_at: 2026-10-19
sources:
  - type: user-confirmed
    reference: On 2026-10-19 the user requested local persistence, recoverable block settings, optional cloud backup, recovery after selling a Mac or losing its SSD, and second-device setup. The user preferred GitHub and requested consultation with Gemini and Claude Code including attachments and Case secrets, with minimal user effort.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Case/CaseVaultStore.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Case/CaseVaultKeyStore.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/Meetings/MeetingsStore.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/History/SQLiteHistoryStore.swift
    confirmed_at: 2026-10-19
  - type: url
    reference: https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
    confirmed_at: 2026-10-19
  - type: url
    reference: https://www.w3.org/TR/webauthn-3/#sctn-prf-extension
    confirmed_at: 2026-10-19
  - type: url
    reference: https://docs.github.com/en/rest/releases/assets
    confirmed_at: 2026-10-19
related: [2026-10-20-simple-github-backup.md, ../project.md, 2026-10-19-backup-management.md, 2026-10-21-backup-tagged-caches.md, 2026-10-21-backup-reliability.md, 2026-10-21-backup-resume-digest.md, 2026-10-21-backup-capture-pacing.md, 2026-10-21-backup-essentials-only.md, 2026-10-21-clipboard-privacy-markers.md, 2026-11-20-settings-sync.md, 2026-11-26-preview-restore-points.md]
---

# Encrypted user artifact backup and recovery

The normal Settings UI is superseded by [the 2026-10-20 simplified GitHub flow](2026-10-20-simple-github-backup.md). Encryption and unfinished maintenance recovery remain applicable.

## Context

The user wants Whytap's working data to remain on their Mac and an optional
off-device backup that can recover settings, provider credentials, Case secrets,
meeting notes and managed attachments after the original Mac is unavailable.
Connecting a second Mac should also be straightforward. GitHub is the preferred
storage candidate. High UX quality includes simple setup, quiet routine backups,
accurate status, safe cancellation and recovery from errors.

The user approved implementation on 2026-10-19 after the joint recommendation.
The implementation uses a random 256-bit recovery credential saved once outside
Whytap, a local Keychain cache, GitHub release assets and an alternative folder
destination. No connector has been enabled for the maintainer and no real user
data has been exported. Source verification and integration follow the shared
application procedure; the local build receipt records the running version.

The settings/key history is independent of cloud setup. Complete archives use
bounded-memory authenticated framing, with all private names and the manifest
inside the encryption. A GitHub snapshot is published only after every part and
its encrypted completion index have been read back and checked. Interrupted
uploads stay drafts. A resumed draft part may instead be confirmed by GitHub's
reported SHA-256 digest of the stored asset; see
[resume digest](2026-10-21-backup-resume-digest.md). Remote versions are retained until the user removes them;
this is not a promise of unlimited storage or indefinite provider availability.

Restore is parked while the runtime is open and applied before AppDelegate on
normal relaunch. The durable transaction must recover both the file stores and
settings/credentials across crashes; every regression in those guarantees is a
release blocker. Local section restore includes a separate provider-key group
and explicit source-default reset for ordinary settings blocks. See
[the user guide](../../docs/backup.md).

The API & Models integration preserves its binary routing document, Anthropic
key and each registered server's canonical UUID credential account. Imported
server definitions may reference only their matching account or the two legacy
server accounts. Metadata rollback captures every incoming key before any write,
including keys absent from the target's current server registry. Settings schema
3 and local history schema 2 distinguish source resets from snapshots predating
the routing document: a reset keeps routes unconfigured, while an older archive
does not erase current routes. Synthetic second-device and interrupted-restore
tests cover those boundaries.
Unreadable routing values are preserved as typed property lists together with
any older unreadable copy; export uses only individually validated server
accounts and reports exclusions. Apply rejects an unmigrated routing document
so legacy migration cannot silently replace restored choices. The UI explains
source resets and independent route/key selection. Credential-only restores
retain imported server keys for a separately restored matching server setup;
they do not silently discard the user's explicitly selected keys.

## Baseline behavior verified before implementation

- Settings use UserDefaults; provider credentials use the application's legacy
  Keychain service. No generic configuration history or cloud backup exists.
- Case has an AES-GCM encrypted vault and a separate 32-byte Keychain key under
  account `case.vault_key`. Copying the vault file alone is insufficient. The
  code requests no synchronization and a device-only accessibility policy;
  this research did not test effective migration behavior of legacy Keychain
  attributes on real user items.
- Meetings use a SQLite catalog plus Markdown notes and transcript JSON files
  under the legacy Sidekey directory. Unfinished recording files have a separate
  staging lifecycle. These require an explicit inclusion policy, not silent loss.
- History uses SQLite plus image files under `history-assets`. Clipboard file
  entries store references to external originals; they do not own those files.
  A path in the backup cannot recover an original lost with the SSD.
- Monitor, Notify and the agent's persistent instructions add application-owned
  files in other legacy roots. Backing up one Application Support directory or
  only preferences cannot be advertised as complete.
- The current community signature has no Apple provisioning profile or data
  protection access-group entitlement. Apple's TN3137 requires an authorized
  profile for those groups. Automatic application access to synchronized iCloud
  Keychain cannot be assumed in this distribution.

## Alternatives

1. **Separate recovery credential, remembered locally.** Generate a random
   backup key, retain it in the local Keychain for automatic work, and ask the
   user once to save a recovery credential outside the Mac. The remote store
   contains authenticated ciphertext. This fits the current community build.
2. **Managed synchronized key service.** Native iCloud Keychain can improve
   recovery UX after the application's signing/provisioning requirements are
   satisfied. That changes distribution requirements and is not currently
   authorized or implemented. An existing password manager can already hold
   a user-saved recovery credential independently of the backup store.
3. **Passkey PRF.** WebAuthn PRF can supply stable per-credential key material.
   Native Apple use requires associated domains; a browser-based HTTPS origin
   is a possible later route. It still needs a stable domain, provider/browser
   support, a secure handoff to the native process and a separate emergency
   recovery path. It is not equivalent to reusing the user's GitHub passkey.

## Selected direction and implementation requirements

Use one locally encrypted backup format with independently recoverable keys.
For an initial community-build implementation, a generated recovery credential
saved once in the user's existing password manager is the practical baseline.
Do not request it for every background backup. Do not promise silent native
"Save to Apple Passwords" integration without a verified API and entitlement
path; deliberate copy/export plus a confirmation is the established baseline.
Copying must also suppress Whytap's own clipboard history, not merely attach
pasteboard privacy markers and assume the watcher respects them.

Preserve GitHub as a storage candidate, but do not append a newly encrypted
whole archive to Git history after each preference change. Release assets offer
a separate upload/download/delete API for encrypted packages; a folder transport
can use the same portable format. Neither API availability nor force-pushing
Git history establishes indefinite storage, garbage collection, a cost guarantee
or a complete retention design. Transport limits and account recovery remain
explicit implementation gates. No hosted Actions are needed or authorized.

The implemented user journey is:

1. In Backup settings, save one recovery credential outside the current Mac.
   Verify that credential by decrypting a test package with the entered code,
   then connect the destination.
2. Save changes locally immediately. Create versioned encrypted snapshots and
   retry remote uploads quietly. Show the actual last completed/verified backup
   and actionable errors. Do not equate saving to a synced folder with confirmed
   off-device upload.
3. On a new Mac, reconnect the destination, supply the saved recovery credential,
   review the snapshot and selected blocks, then restore. Preserve the target's
   existing data and keys until validation and a rollback checkpoint complete.

Backup and synchronization are separate: a second Mac may restore a snapshot,
but automatic merging between independently edited Macs is not implied.

## Rationale and acceptance gates

- Encrypt secrets and private metadata before upload. Authentication to GitHub
  grants access to objects; it is not an encryption key. Public names, IDs and
  rotating OAuth tokens are unsuitable recovery keys. Keep the recovery key
  outside the repository, including outside its history and release assets.
- A complete backup must include an independently recoverable representation
  of Case and its key material. Restoration into an existing vault must not
  discard that Mac's unrelated secrets. Temporary plaintext export files are
  not an acceptable shortcut.
- Use SQLite's supported snapshot mechanism plus an application-level barrier
  or immutable generation to capture the database and its referenced files
  consistently. SQLite's backup API alone does not coordinate external files.
  Missing required attachments make a backup incomplete.
- Upload immutable data first and publish a completed snapshot only after all
  required objects are present and verified. Interruptions must leave the last
  complete version usable. Retention must preserve pinned known-good versions.
- Restore into staging, validate authentication, schemas, SQLite integrity and
  required file bytes, then commit with rollback. Reject future schemas without
  resetting current data. Do not restore machine permissions or automatically
  execute imported scripts and unfinished jobs.
- Prove recovery with synthetic credentials, Case values, notes and attachment
  bytes in a clean profile with an empty Keychain stub. Verify interrupted
  uploads/restores, concurrent saves, corruption, disk-full and offline states.
  Visual checks must cover setup, pending, errors, restore preview and completion.
- A compromised remote account can delete ciphertext even when it cannot read
  it. Keep independent local history; an optional second destination addresses
  loss of the sole cloud copy. Losing all copies or every recovery method cannot
  be repaired by encryption. State these limits without promising absolute safety.

## Comments and objections

Gemini's initial report proposed recovery keys and GitHub/folder transports.
After challenge, it withdrew unsupported size/coverage estimates, a two-second
restore promise, claims that force-pushing bounds GitHub storage, and assumed
one-click Passwords integration. Those claims are not accepted requirements.

Claude Code independently recommended a folder-first implementation, a separate
recovery credential and re-encrypting recovered Case contents with the target
Mac's own local vault key. It also identified the need to verify the effective
legacy Keychain accessibility policy, rather than trusting a device-only code
comment. Its small-data estimates and default exclusion of large attachments
are not accepted as coverage guarantees: this user's request explicitly includes
attachments. Staged audio may be transient after successful processing but can
be the only source for a failed meeting, so it cannot be excluded merely because
its directory is named staging.

Both consultations support the key-management baseline. Implementation preserves
the user's GitHub choice behind the same encrypted format as a folder destination.
It does not implement passkey-based key derivation or continuous synchronization.

## Verified implementation contracts

- Complete archives authenticate bounded chunks with independent random salts,
  a 32-byte secret, HKDF-SHA256 and AES-GCM. Names, manifests, hashes, keys and
  private content are encrypted. Limits are 8 GiB per file, 64 GiB per archive
  and 200,000 entries; exceeding a bound refuses the snapshot.
- Local full copies are independent. GitHub transfers can reuse unchanged
  entries from a previously checked snapshot; chains are capped at 32 deltas,
  after which a standalone full copy is sent. Remote ancestors are not pruned.
- Only a checked release is published. Failed GitHub uploads reuse their saved
  draft and exact encrypted payload; incomplete draft assets can be replaced.
  Public repositories are refused. Upload parts adapt to the release asset cap.
- Before any restore mutation, the original preferences and provider keys are
  sealed in a durable encrypted before-state and file moves are journaled.
  Atomic journal replacement and directory synchronization protect rename
  boundaries. A completed commit is authenticated and finalization can resume
  without rolling back the successfully imported workspace.
- Failed rollback or temporarily inaccessible keys preserve every transaction
  record for retry, regardless of retry count. Successful restores retain all
  replaced-file generations and generation-specific before-state keys. The UI
  exposes their location, planned-restore cancellation and parked-item activation.
  A saved recovery code can unlock the pending transaction before runtime opens.
  An early modal return cannot start another apply while its worker runs;
  repeated retries do not cancel a planned restore. Unreadable old recovery-key
  metadata is preserved inside Keychain while a new generation is retained.
- Local settings history retains 300 read-verified versions, full local backups
  retain the latest 30 copied versions plus every unsent or pre-restore copy
  (since 2026-10-21 only the newest copied archive, see
  [backup capture pacing](2026-10-21-backup-capture-pacing.md)).
  Corrupt/unreadable local versions are not silently pruned. GitHub copies are
  never automatically deleted. Backups are best-effort while the app is open;
  status reports the latest completed copy rather than promising zero data loss.
- Verification uses isolated profiles, fake credentials and mocked GitHub HTTP.
  Clean-profile tests cover notes, app-managed images, provider credentials and
  Case merge; fault tests cover metadata rollback, interrupted file moves,
  repeated locked-key failures, committed finalization and retained generations.
  Offscreen native renders cover setup, configured/error, preview and pending
  restore states. No maintainer account or real archive has been uploaded.

## Decision and resolution

Implementation is authorized. Source, coherent exports, encrypted transport,
clean-profile recovery and visual checks are integration gates. The maintainer
must explicitly connect a destination and save the recovery credential in the
finished UI; development checks use synthetic profiles and stub credentials.
Merging or installing the feature does not configure or upload a user backup.

## Sources

- [Apple: macOS Keychain implementations and provisioning](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- [Apple: supporting passkeys and associated domains](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys/)
- [W3C: WebAuthn PRF](https://www.w3.org/TR/webauthn-3/#sctn-prf-extension)
- [Encryption using saved passkeys — 1Password](https://1password.com/blog/encrypt-data-saved-passkeys)
- [GitHub: large files and repository guidance](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github)
- [GitHub: release asset API](https://docs.github.com/en/rest/releases/assets)
- [SQLite: online backup](https://sqlite.org/backup.html)
- Gemini consultation: Antigravity conversation `b668e032-2850-4ca1-98fa-4cf44eb0d8e7`,
  including correction job `1792420131312544000-0f9708de34c9d775961cac47`.
- Claude Code consultation: completed job `c525ddc8-e7d6-4e13-a610-ac490f40ae46`,
  resolved model `claude-opus-5`; recommendations and source-based caveats were
  checked against the repository and primary documentation.

## Consequences

This is broader than a text configuration export. A successful status requires
coherent store exports and complete authenticated recovery, not only successful
HTTP requests. Legacy settings, paths and Keychain services are preserved.
Whytap's own clipboard watcher suppresses copied recovery credentials. Other
clipboard applications decide how they handle private pasteboard markers.

## Supersedes / superseded by

None. This records a new capability and does not supersede the current
local-storage or shared-application procedures.
