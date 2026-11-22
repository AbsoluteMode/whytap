# Security policy

Whytap runs entirely on your Mac. It has no accounts, no Whytap servers and
no telemetry. Every way data can leave the Mac is listed in the
[network routes table](docs/privacy.md#what-can-leave-the-device-and-only-when-you-choose-it)
of the privacy document, which is kept current with each release.

## Reporting a vulnerability

Please do not open a public issue for security problems. Use
[private vulnerability reporting](https://github.com/AbsoluteMode/whytap/security/advisories/new)
on GitHub, or email contact@maxbutorin.dev, with a description, the affected
version and reproduction steps. You will get an acknowledgement within a few
days and a fix or a mitigation plan as soon as we have one. Coordinated
disclosure is appreciated; we will credit you in the release notes unless you
prefer otherwise.

## Supported versions

Only the latest release on the GitHub Releases page receives fixes.

## Scope notes

- API keys you enter (BYOK) are stored in the macOS Keychain under the app's
  own service name and are sent only to the provider you selected.
- Transcripts, meeting notes and history live in SQLite files under
  `~/Library/Application Support/`. They never leave the machine unless a
  provider or endpoint you configured is involved, or you turn on encrypted
  Backup or settings sync to your own GitHub repository.
- The built-in Agent is off by default. Once on, it can write files and run
  shell commands as your user unless you turn off **Allow file edits and
  commands**; this is an action policy, not a sandbox
  ([Whytap Agent](docs/agent.md)).
- Global hotkeys use a `CGEventTap` that reads key events only to detect the
  configured trigger key; key contents are never logged or persisted.
