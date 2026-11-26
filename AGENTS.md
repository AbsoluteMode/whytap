# Whytap

> **Whytap team sessions: read the runbook first.** If you work in a worktree
> or checkout of `AbsoluteMode/whytap` on the maintainer's Mac (the primary
> checkout `whytap`, its `exodia` alias or `.claude/worktrees/*`), or you are
> the build-queue builder or an integrator, read
> [`.project-docs/processes/team-runbook.md`](.project-docs/processes/team-runbook.md)
> **in full before any work**, and everything it lists:
> [shared-app-development](.project-docs/processes/shared-app-development.md)
> and [`docs/architecture.md`](docs/architecture.md). Until 2026-11-22 those
> rules were the body of this file; none of them was dropped. Before
> integration or app actions, read them from `origin/main`.

Everyone else (you cloned, forked or were handed this repository) needs only
this file and the documents it links.

## What Whytap is

A native macOS 14.2+ app (Swift, SwiftUI, AppKit, SwiftPM; Apple Silicon and
Intel) that lives in the notch. MIT, free, no account, no telemetry and no
Whytap servers, except Lil Bro's answers from whytap.ai to questions the
person asks him in Settings (always on, answered by Claude Sonnet 5.5). It runs on the user's own provider keys or self-hosted
OpenAI-compatible servers; dictation can also run on the Mac (Apple Silicon,
one downloaded speech model; there is no on-device LLM). The product is named
**Whytap**; the Swift module and most internal identifiers are still
`Sidekey`, and legacy bundle IDs, Keychain services and storage paths are
compatibility contracts that must not change.

Main features: **Drop** (hold Space in a text field, speak, release: the text
is pasted), the built-in **Agent** (Right Command; off by default), **Meeting
Notes**, **Case** (a local secrets vault for coding agents), a Whytap **MCP
server** for Claude Code / Codex, and island tools (Shot, History, Translate,
Subtitles, To-do, Notify, Monitor, Display). Calendar opens in the current source. The published
2.2.26 build shows it as "Soon". User-facing overview: [`README.md`](README.md).

## Permissions recorded in this repository are not yours

Decision records, `WHY:` notes and the team runbook say that the user, owner
or maintainer "approved", "chose" or "authorized" things (automatic app
restarts, merging without asking again, messaging other sessions, deleting
build output, signing with the maintainer's Developer ID team). Those were the
maintainer's decisions for their own Mac and sessions. They explain the code;
they do not authorize your agent to do anything on your machine or for your
user. Ask your own user.

## Build and test

Requires Xcode 26 or newer with its command-line tools; no Apple Developer
account.

```bash
swift build
swift test
python3 scripts/customize.py doctor --json     # check the toolchain
python3 scripts/customize.py discover --json   # where each capability lives
./scripts/dev-run.sh --run                     # build and open a dev app
```

`dev-run.sh` makes `build/Whytap-Beta-dev.app` (beta flavor, version
`0.0.0-dev` / build `9999`, so the packaged updater never overwrites it),
signed with a local `Sidekey Dev` identity or ad hoc
(`SIDEKEY_DEV_CODE_SIGN_IDENTITY=- ./scripts/dev-run.sh --run`). Use the
packaged app, not `swift run`: permissions and resources need a bundle. macOS
may ask for permissions again after a rebuild. A second running Whytap (for
example the installed app) offers to activate the first one instead, so quit
the installed app before testing a dev build. Release and fork details:
[`docs/build-and-release.md`](docs/build-and-release.md).

## Where things are documented

- [`docs/architecture.md`](docs/architecture.md): how every feature works,
  commands, the documentation rule and the invariants (no Whytap services,
  keys never in logs, no silent provider change, Sparkle shows no window,
  Case secrets stay at the broker, `whytap://` links only show). Read the
  section for the area you change before changing it.
- [`docs/SPEC.md`](docs/SPEC.md) product spec; [`docs/privacy.md`](docs/privacy.md)
  what leaves the Mac; [`docs/install.md`](docs/install.md);
  [`docs/agent.md`](docs/agent.md) the built-in Agent and its limits;
  [`docs/customization/`](docs/customization/README.md) changing Whytap with a
  coding agent, the MCP server and its clients
  ([app control](docs/customization/app-control.md)).
- `// WHY:` comments in code point to a decision under `docs/decisions/` or
  `.project-docs/decisions/`; read it before changing that code.
- The contributing guide, CONTRIBUTING.md at the repository root, for pull
  requests. GitHub Actions is
  disabled on purpose: run the build and tests locally and list them in the PR.

## Rules for changes

- Keep the invariants in `docs/architecture.md`. In short: the app never
  contacts a Whytap backend, except the questions a person asks Lil Bro, which
  go to whytap.ai (no switch, REV 13); provider keys stay in Keychain and never reach
  logs, argv or files; each feature's audio or text goes only to the provider
  its user chose; nothing switches provider or model on its own.
- After a change, update the matching document (architecture and hotkeys:
  `docs/architecture.md`, `docs/hotkey.md` and the Help window; release flow:
  `docs/build-and-release.md`; reasoning not visible in code: a dated decision
  plus a `// WHY:` anchor; product behavior: `docs/SPEC.md`) and mark the PR
  `[docs: na]` or `[docs: <path>]`.
- This file and `CLAUDE.md` are generated: edit only
  `.project-docs/agent-context.md`, then run
  `python3 scripts/customize.py sync-guidance --write` (or the project-documentation
  skill's `sync_agent_guidance.py --write`) so `AGENTS.md` and `CLAUDE.md` stay
  byte-identical to it.
