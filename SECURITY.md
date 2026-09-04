# Security policy

Whytap runs entirely on your Mac. It has no accounts, no Whytap servers and
no telemetry. The only network traffic is what you configure yourself: model
downloads from Hugging Face, calls to a speech or LLM provider using your own
API key, Sparkle update checks, and the local Claude Code / Codex CLI you
connect as the agent.

## Reporting a vulnerability

Please do not open a public issue for security problems. Email
security@whytap.ai with a description, the affected version and reproduction
steps. You will get an acknowledgement within a few days and a fix or a
mitigation plan as soon as we have one. Coordinated disclosure is
appreciated; we will credit you in the release notes unless you prefer
otherwise.

## Supported versions

Only the latest release on the GitHub Releases page receives fixes.

## Scope notes

- API keys you enter (BYOK) are stored in the macOS Keychain under the app's
  own service name and are sent only to the provider you selected.
- Transcripts, meeting notes and history live in SQLite files under
  `~/Library/Application Support/`. They never leave the machine unless a
  BYOK provider or your agent CLI is involved.
- Global hotkeys use a `CGEventTap` that reads key events only to detect the
  configured trigger key; key contents are never logged or persisted.
