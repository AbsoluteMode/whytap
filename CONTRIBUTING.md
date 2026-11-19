# Contributing to Whytap

Thanks for helping. Whytap is a native macOS app (Swift, SwiftUI, AppKit,
SwiftPM). Users bring their own provider keys or OpenAI-compatible endpoints.
Pull requests that preserve this independence from Whytap services are welcome.

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

Maintainer sessions developing features in parallel follow
[the shared application procedure](.project-docs/processes/shared-app-development.md).
They compile/test in separate worktrees, automatically enqueue their reviewed
PR/head, and leave integration, app packaging, installation and launch to the
designated queue builder. The standalone commands below
must not be run from a parallel feature session.

Use macOS 14.2 or newer and Xcode 26 or newer with a Swift 6 toolchain
(`swift-tools-version:6.0`, Swift 5 language mode). No Apple Developer
account, Developer ID certificate or notarization is required.

```bash
git clone https://github.com/AbsoluteMode/whytap.git
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
customizations. Update your source with the agent, preserve local changes and
rebuild with the same script.

## Pull requests

1. Branch from `main`.
2. Keep the change focused; add or update tests next to the code you touch.
3. For runtime changes, `swift build` and `swift test` must pass locally on the
   final integrated candidate. Documentation-only changes run the relevant
   documentation/link/guidance checks and mark Swift checks not applicable.
4. Describe what changed and why in the PR body. Note any docs you updated
   (`CLAUDE.md` architecture notes, `docs/hotkey.md`, `docs/build-and-release.md`).
5. Maintainers squash-merge.
6. Include dependencies/overlaps, the reviewed head/base and 1–3 concrete
   acceptance steps. State separately whether the feature is ready, merged,
   waiting in a candidate or verified in the user's working app. A merge alone
   never means that app was updated.

Builds and tests run locally. GitHub Actions is disabled to avoid hosted-runner
costs. Include the local validation result in the PR. Ready-made community
builds and in-app updates are the main distribution path; source customization
remains supported. The default release pipeline signs with the Developer ID
certificate of Whytap's Apple team, which only maintainers hold, and Whytap's
Sparkle archive signatures; published releases are also notarized by Apple with
the team's App Store Connect key. Contributors do not need an Apple Developer
account (see `docs/build-and-release.md`).

By contributing you agree that your contribution is licensed under the MIT
License of this repository. No CLA is required.

## Reporting bugs

Use the issue templates. Include the macOS version, the Mac model (Apple
Silicon or Intel), the Whytap version from Settings, and which speech / LLM
route you use (your own key or custom endpoint).
