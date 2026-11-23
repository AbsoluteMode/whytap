# Contributing to Whytap

Thanks for helping. Whytap is a native macOS app (Swift, SwiftUI, AppKit,
SwiftPM). Users bring their own provider keys or OpenAI-compatible endpoints.
Pull requests that preserve this independence from Whytap services are welcome.

Looking for a place to start? Issues labelled
[`good first issue`](https://github.com/AbsoluteMode/whytap/labels/good%20first%20issue)
name the files to change and how to check the result.

## Your first pull request

1. **Fork** [AbsoluteMode/whytap](https://github.com/AbsoluteMode/whytap) on
   GitHub and clone your fork.
2. **Build and run** a development copy (see [Building](#building)):

   ```bash
   ./scripts/dev-run.sh --run
   ```

3. **Make the change** on a branch of your fork, with a test next to the code
   you touch.
4. **Test** locally:

   ```bash
   swift build
   swift test
   ```

   Documentation-only changes do not need the Swift checks; say so in the PR.
   The run is silent and ends with a `SystemSoundGuard` line; a test that
   sends a key nothing takes fails, because the app would beep there too.
5. **Open a pull request** against `main`. Say what changed, why, and how you
   checked it. A maintainer reviews it and squash-merges.

You do not need an Apple Developer account, a certificate or access to any
Whytap infrastructure. GitHub Actions is disabled, so no CI runs on your PR:
paste the result of your local `swift test` into the PR instead.

## Ground rules

- No Whytap-owned servers, accounts or telemetry. Network calls are limited
  to user-configured providers, monitoring sources and credential stores,
  model/OpenCode downloads and the Sparkle update feed. `Tests/SidekeyTests/CloudRemovalTests.swift`
  enforces this at build time.
- Privacy in logs: never interpolate transcripts, prompts, replies or API keys
  into `os_log`. `Tests/SidekeyTests/LLM/LocalPathLoggingInvariantTests.swift`
  guards the provider paths that carry this content.
- No emoji in code, comments or commit messages.
- Hotkeys follow `docs/hotkey.md` (single `HotkeyHintView` entry point, a row
  in the Help window for every new shortcut).
- Behavioural changes that need a "why" get a short decision document in
  `docs/decisions/YYYY-MM-DD-<slug>.md` and a `// WHY:` anchor next to the
  code. Read the linked document before changing code that carries one.

## Building

Use macOS 14.2 or newer and Xcode 26 or newer with a Swift 6 toolchain
(`swift-tools-version:6.0`, Swift 5 language mode). No Apple Developer
account, Developer ID certificate or notarization is required.

```bash
git clone https://github.com/<your-account>/whytap.git
cd whytap
./scripts/dev-run.sh --run
swift test
```

The script creates `build/Whytap-Beta-dev.app` for testing on the same Mac.
It uses an existing local `Sidekey Dev` signing identity or falls back to
ad-hoc signing. Use it rather than `swift run` to preserve the app bundle
path and identity. Ad-hoc rebuilds may require granting macOS permissions
again. This development bundle is separate from ready-made releases and uses
`0.0.0-dev` / build `9999`, so the binary feed does not overwrite local
customizations. Quit an installed Whytap before running the development copy:
only one copy runs at a time.

If the build fails, `python3 scripts/customize.py doctor --json` checks the
toolchain and prerequisites.

## Pull requests

1. Branch from `main`.
2. Keep the change focused; add or update tests next to the code you touch.
3. For runtime changes, `swift build` and `swift test` must pass locally.
   Documentation-only changes mark the Swift checks not applicable.
4. Describe what changed and why in the PR body. Note any docs you updated
   (`docs/architecture.md`, `docs/hotkey.md`, `docs/build-and-release.md`).
5. Maintainers squash-merge.

Ready-made community builds and in-app updates are the main distribution path;
source customization remains supported. The release pipeline signs with the
Developer ID certificate of Whytap's Apple team, which only maintainers hold,
and Whytap's Sparkle archive signatures; published releases are also notarized
by Apple (see `docs/build-and-release.md`).

By contributing you agree that your contribution is licensed under the MIT
License of this repository. No CLA is required.

## Reporting bugs

Use the issue templates. Include the macOS version, the Mac model (Apple
Silicon or Intel), the Whytap version from Settings, and which speech / LLM
route you use (your own key, a custom endpoint or On this Mac). For questions
and setup help, ask on [whytap.ai](https://whytap.ai) first.

## Maintainers only

Maintainer sessions developing features in parallel follow
[the shared application procedure](.project-docs/processes/shared-app-development.md).
They compile and test in separate worktrees, never launch or install their own
app, and must not run `dev-run.sh` or other packaging commands. Each finished
feature automatically enqueues its reviewed PR/head in the local build queue;
the designated queue builder alone integrates, packages and updates the
maintainer's working app.

A maintainer PR additionally records the reviewed head/base and
dependencies or overlapping work, 1–3 concrete acceptance steps, the build
queue ticket, and whether the feature is ready, merged, waiting in a candidate
or verified in the working app. A merge alone never means that app was
updated. Integration runs the full `swift build` and `swift test` on the final
combined candidate.
