---
id: whytap-name-2026-10-19
type: decision
title: Restore the Whytap product and repository name
summary: Return public branding to Whytap while preserving signing, stores, encrypted backups and existing update links.
status: confirmed
tags: [branding, repository, compatibility, macos]
canonical_for: [product-name]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user reaffirmed that the project is Whytap, not Exodia, and requested correction of all remaining stale naming information.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-19 the user chose Whytap, stated ownership of whytap.ai and asked to rename everything back from Exodia.
    confirmed_at: 2026-10-19
  - type: repository
    reference: Sources/Sidekey/BuildConfig.swift
    confirmed_at: 2026-10-19
  - type: repository
    reference: scripts/build-dmg.sh
    confirmed_at: 2026-10-19
related: [../project.md, ../processes/shared-app-development.md, 2026-10-19-shared-working-app.md, 2026-10-17-exodia-name.md, 2026-11-21-whytap-backup-repository.md]
---

# Restore Whytap

## Context

The product and public repository were briefly named Exodia. The user owns
whytap.ai and requested a return to Whytap on 2026-10-19.

## Alternatives

Keep Exodia or restore Whytap. The user selected Whytap.

## Decision

Use **Whytap** for the product, app bundle names, interface, agent identity,
current guides and new release artifacts. The public source repository is
`AbsoluteMode/whytap`; rename the existing repository in place so its numeric
identity, issues, pull requests, history and released assets survive.

The user reaffirmed this name on 2026-10-21. The canonical primary checkout folder
is named `whytap`; an older `exodia` path can remain a compatibility symlink.
User-level harness instructions and current project guidance must use
Whytap and must not treat that old path or historical sessions as current branding.

## Rationale

The name matches the user's existing domain and the app's shortcut interaction.
The domain is a product address, not a new application backend or update host.

## Compatibility and consequences

- Keep Sidekey targets, executable, bundle IDs, Keychain services, preference
  keys, Application Support directories and the common runtime lease unchanged.
- Keep the existing community certificate (including its Exodia CN), its
  designated requirement and Sparkle keys. Never create a replacement identity
  for this rename. Existing permissions and credentials must remain usable.
- Preserve encrypted backup formats, extensions, authenticated strings and
  established `Exodia-Backup` destinations (new GitHub connections create
  Whytap-Backup since 2026-11-21: 2026-11-21-whytap-backup-repository.md).
  New folder setup uses Whytap Backups;
  selecting an existing Exodia Backups folder reuses it.
- Keep `EXODIA_*` release credentials/options and bundle metadata keys compatible
  with existing tools. Notify exposes WHYTAP_NOTIFY_SOURCE and
  WHYTAP_NOTIFY_DIRECTORY plus their existing EXODIA aliases.
- Keep `exodia-integration.lock` as the shared development lock so older sessions
  and this rename still serialize against each other. Do not rename occupied
  checkouts or other sessions' worktrees. The primary receipt remains at
  the existing primary checkout’s build receipt.
- Existing Exodia GitHub URLs redirect after the repository rename. Do not
  relabel old sealed DMGs or claim a new public binary release. Until a new
  release is published, its latest package can still be Exodia-latest.dmg.
- The canonical working app is `/Applications/Whytap.app`; the primary build
  receipt records its verified running version and source. An older bundle
  must only be replaced at a checked safe promotion. A documentation edit or
  repository rename alone does not update the running application.

## Sources

The dated user request above and the build/source contracts listed in frontmatter.

## Comments and objections

No additional product objections were supplied. Preserve compatibility instead
of changing data formats or certificate identity to erase historical spelling.

## Resolution

Restore public branding and keep technical compatibility contracts.

## Supersedes / superseded by

Supersedes [the Exodia naming decision](2026-10-17-exodia-name.md).
