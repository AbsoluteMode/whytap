# Ship mlx.metallib as a sealed resource (symlinked), not detached-signed nested code

Date: 2026-06-30

## Context

The first MLX release (1.15.0 / build 1414, shipped 2026-06-29) introduced a
fresh-install Gatekeeper failure that only reproduced on **macOS 15 (Sequoia)**:

> "Apple could not verify 'Whytap' is free of malware that may harm your Mac…"

with only "Move to Trash" / "Done" — the app opens **only** via System Settings ›
Privacy & Security › Open Anyway. It did **not** reproduce on macOS 26 (Tahoe) or
27. Affected users were doing a clean DMG install (drag to /Applications, first
launch). Reports clustered in Russia.

The artifact itself checked out clean on every static probe, on both an Apple
Silicon dev box (macOS 27) **and** a real failing 15.7.3 machine:

- `xcrun stapler validate` — worked on the DMG and the `.app` (ticket stapled on both)
- `spctl -a -t exec` — accepted, `source=Notarized Developer ID`
- `codesign --verify --deep --strict` — valid on disk, satisfies Designated Requirement
- both arch slices valid + stapled; signing cert valid, not revoked
- bundle perms 0755/0644; no restricted entitlements; no `SUEnableInstallerLauncherService`

So the failure was **not** a signing/notarization defect in the bits, and it was
invisible to `spctl`/`codesign`. That asymmetry (passes locally, blocks at GUI
first-launch, Sequoia-only) is the whole bug.

## Decision

Stop shipping `mlx.metallib` as a separately code-signed file inside
`Contents/MacOS/`. Instead:

- ship it as an ordinary **sealed resource** at `Contents/Resources/mlx.metallib`
  (hashed into `_CodeSignature/CodeResources` by the final app sign), and
- place a **relative symlink** `Contents/MacOS/mlx.metallib -> ../Resources/mlx.metallib`
  so MLX's colocated loader still resolves it.

Remove the explicit `codesign … mlx.metallib` step. `build-dmg.sh` and
`dev-run.sh` both adopt this layout (dev mirrors prod so dev runs exercise the
same colocated-via-symlink path).

## Why

`mlx.metallib` is a `Format=generic` **non-Mach-O** object. `codesign` cannot
embed a signature into it, so signing it produced a **detached** signature in the
`com.apple.cs.CodeSignature` xattr and recorded it in `CodeResources` as a nested
**code** item — one that, being a bare generic file, can carry no stapled
notarization ticket of its own.

On Sequoia, the quarantined first-launch Gatekeeper path appears to validate that
un-stapleable nested code object **online** (the outer DMG/app ticket does not
cover it the way Tahoe's path accepts). When that online confirmation is
blocked/slow — Apple Gatekeeper/notarization endpoints unreachable from some
networks (the Russia cluster) — the launch hard-fails with "could not verify".
`spctl`/`codesign` keep passing because they honor the **outer** stapled ticket
locally and don't exercise the GUI quarantine online path. Tahoe honored the
outer ticket and never went online for the metallib → no block.

Re-homing the metallib as a sealed resource removes the nested-code object
entirely: it is now validated by a hash in `CodeResources` (which the outer
staple covers), with no detached xattr and no separate online-notarization
surface. The symlink keeps MLX's `load_default_library()` working — it tries
`<binary_dir>/mlx.metallib` first (`device.cpp`), and `<binary_dir>` is
`Contents/MacOS/`, so the symlink is followed transparently. A **relative**
symlink also survives App Translocation.

## What we tested

- **Multi-engine triage** (Storm: Claude+GLM+Gemini; plus a Codex deep pass that
  inspected the artifact itself). Consensus: "could not verify" = notarization
  *confirmation* failing at GUI first-launch via an online check; Codex pinned the
  trigger to the new non-stapleable `mlx.metallib` nested-code object. Gemini's
  "xattr stripped in transit" variant was **refuted** — `--deep --strict` passes
  on the real 15.7.3 box, so the xattr is intact there.
- **Reproduced the signing shape locally**: confirmed `mlx.metallib` ships as
  `Format=generic`, signed via a detached `com.apple.cs.CodeSignature` xattr, and
  recorded as nested code in `CodeResources`.
- **Approach A (chosen) — Resources/ + symlink**: re-signed a copy of the app;
  `codesign --verify --deep --strict` passes, the metallib is now `code object is
  not signed at all` and appears under `CodeResources` `files2` as a plain
  `hash2` sealed resource, with the detached signature xattr gone.
- **Approach B — `Contents/MacOS/Resources/mlx.metallib` (no symlink, MLX search
  path #2)**: **rejected** — `codesign` treats everything under `Contents/MacOS/`
  as code, leaves the generic file "not signed at all", and `--verify --deep
  --strict` fails with "a sealed resource is missing or invalid".

## Rejected alternatives

- **Leave it in `Contents/MacOS/`, just stop signing it** — `--deep --strict`
  fails ("not signed at all"); that's why it was being signed in the first place.
- **`Contents/MacOS/Resources/mlx.metallib`** — codesign won't seal a non-Mach-O
  under the MacOS dir as a resource (tested, fails).
- **Set an explicit metallib path from Swift / an env var** — mlx-swift 0.31.4
  exposes no such API; the loader is colocated-only.
- **Ship a `.pkg` installer to bypass the quarantine drag-copy path** — heavier
  distribution change; keep DMG + Sparkle, fix the root cause instead.
- **Downgrade the build/staple toolchain (Xcode 16 / macOS 15 SDK)** — unproven,
  and doesn't address the nested-code object that Codex identified as the trigger.

## Verification gate

The decisive proof is a freshly built, notarized, **stapled** test DMG opening on
a real Sequoia 15.x machine in the affected network **without** any user action.
Local `codesign --verify --deep --strict` + successful Apple notarization of the
symlinked layout is the pre-flight; an affected user simply downloading and
opening the new build is the confirmation.

PR/commit: _pending_ — branch `claude/cool-wozniak-598e45`.
