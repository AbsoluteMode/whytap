# Contributing to Whytap

Thanks for helping. Whytap is a native macOS app (Swift, SwiftUI, AppKit,
SwiftPM). Everything runs on the user's machine, and pull requests that keep
it that way are very welcome.

## Ground rules

- No Whytap-owned servers, accounts or telemetry. Network calls are allowed
  only towards services the user configured with their own keys, model
  downloads, and the Sparkle update feed. `Tests/SidekeyTests/CloudRemovalTests.swift`
  enforces this at build time.
- Privacy in logs: never interpolate transcripts, prompts, replies or API keys
  into `os_log`. `Tests/SidekeyTests/LLM/LocalPathLoggingInvariantTests.swift`
  guards the local pipelines.
- No emoji in code, comments or commit messages.
- Hotkeys follow `docs/hotkey.md` (single `HotkeyHintView` entry point, a row
  in the Help window for every new shortcut).
- Behavioural changes that need a "why" get a short decision document in
  `docs/decisions/YYYY-MM-DD-<slug>.md` and a `// WHY:` anchor next to the
  code. Read the linked document before changing code that carries one.

## Building

Requirements: macOS 14.2 or newer, Xcode with a Swift 6 toolchain
(`swift-tools-version:6.0`, Swift 5 language mode). Local speech and LLM
models need Apple Silicon; on Intel the app works with your own provider keys.

```bash
swift build
swift test
./scripts/dev-run.sh --run     # builds a dev bundle with a stable ad-hoc identity
```

Use `dev-run.sh` rather than `swift run`: it keeps the same code-signing
identity between builds so that the Accessibility, Microphone and System
Audio grants you gave the dev bundle persist.

## Pull requests

1. Branch from `main`.
2. Keep the change focused; add or update tests next to the code you touch.
3. `swift build` and `swift test` must pass locally.
4. Describe what changed and why in the PR body. Note any docs you updated
   (`CLAUDE.md` architecture notes, `docs/hotkey.md`, `docs/build-and-release.md`).
5. Maintainers squash-merge.

By contributing you agree that your contribution is licensed under the MIT
License of this repository. No CLA is required.

## Reporting bugs

Use the issue templates. Include the macOS version, the Mac model (Apple
Silicon or Intel), the Whytap version from Settings, and which speech / LLM
route you use (local model, your own key, custom endpoint).
