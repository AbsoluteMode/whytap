# Whytap becomes a fully local open-source tool

## Context

Until September 2026 Whytap was a freemium product: the client was private,
speech recognition ran through a Whytap backend hub (Soniox), text cleanup
through `/api/process`, meetings through a meetings backend, and an OAuth
login plus a free/pro tier gated the local and bring-your-own-key paths.
The June 2026 plan was to open the client under FSL and keep the backend
as the paid moat.

## Decision

Whytap is a free, MIT-licensed, fully local macOS tool, developed in the
public repository `AbsoluteMode/whytap`. The app runs without an account,
without Whytap servers and without telemetry. Speech and text models run on
the device (Apple Silicon) or at a provider chosen by the user with their
own key; the agent is the user's local Claude Code or Codex CLI.

Removed from the code base: OAuth/JWT and the login screen, tiers, quotas
and the pricing screen, the backend hub streaming path and the batch
`/api/transcribe` fallback, `/api/process`, the cloud meetings pipeline,
event telemetry, heartbeat and crash reporting, server-synced preferences,
the notifications connectors (Slack, Telegram, Linear, GitHub), the B2B
product line, the Windows stub, the landing site and server configs.

Kept: local Parakeet STT, BYOK STT adapters, local MLX cleanup and meeting
summaries, OpenRouter and custom OpenAI-compatible endpoints, the local agent
bridge, fully-local and BYOK meetings, Dynamic Island, hotkeys, history,
Now Playing, Sparkle updates.

## Why

- Every local path already existed (Parakeet, MLX, BYOK, local agent); the
  cloud layer only added an account, cost and a gate in front of them.
- A privacy claim that can be checked by reading the code is the
  differentiator; a paid backend contradicts it.
- Running the backend, auth service, payments and legal paperwork had a
  fixed cost and no revenue; removing them leaves the Apple Developer
  membership as the only recurring expense.
- MIT rather than FSL or GPL: no monetization to protect, and the lowest
  friction for contributors. Copyright stays with the author personally,
  which avoids the rights-transfer paperwork a company licensor would need.

## What we tested

- Inventory of the cloud coupling: 60 cloud-only files (about 11k lines),
  14 mixed directories, roughly 121 tests deleted, 48 rewritten, 275
  untouched.
- A guard test (`CloudRemovalTests`) fails the build if a Whytap hostname or
  a removed symbol reappears in `Sources/`.
- `gitleaks` over the full private history found only Paddle client tokens
  in landing bundles (public by design) and example keys in plans.

## Rejected

- Open client with a closed backend under FSL plus a subscription: keeps
  the fixed costs, contradicts the privacy story.
- Keeping the notifications connectors as a BYO-token subset: Slack and
  Linear need OAuth apps registered by the maintainer, GitHub had no direct
  client at all.
- Publishing the private repository with a rewritten history: internal
  documents, a user's email and a team id sit in hundreds of commits;
  a fresh history in a new repository is safer.
- Hosting the appcast on `updates.whytap.ai`: GitHub Releases is free and
  survives the domain.

## Migration

Users on 1.18.x still read `updates.whytap.ai`. The first open-source
release is published on that feed one last time, and the build it ships
already points Sparkle at GitHub Releases. The backend is switched off only
after that release has been available long enough.

2026-09-04. Plan and inventory: `../plans/2026-09-02-fully-local-open-source.md`.
