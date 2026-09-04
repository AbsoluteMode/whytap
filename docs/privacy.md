# Privacy

Whytap has no accounts, no Whytap-operated servers and no telemetry. This
document lists every way data can leave the Mac, so that "fully local" is a
verifiable claim rather than a slogan.

## What stays on the device

- Audio captured for dictation (Drop) and for meetings is processed in memory
  and, for meetings, staged as WAV chunks under `~/Library/Application
  Support/` only until the local pipeline has transcribed them.
- Transcripts, agent history, clipboard history and meeting notes live in
  SQLite databases under `~/Library/Application Support/`. Delete them from
  Settings, History, or by removing the files.
- API keys you enter ("Your key") are stored in the macOS Keychain under the
  app's own service name (`com.rootwise.sidekey`).
- Logs go to the unified system log (`os_log`, subsystem
  `com.rootwise.sidekey`). They never contain transcripts, prompts, replies
  or keys; `Tests/SidekeyTests/LLM/LocalPathLoggingInvariantTests.swift`
  enforces that for the local pipelines.

## What can leave the device, and only when you choose it

| Route | Where data goes | When |
|---|---|---|
| Local models (Parakeet, FluidAudio diarization, MLX Qwen3) | nowhere; a one-time download from Hugging Face fetches the weights | Apple Silicon, after you click Download |
| Your key (OpenAI, Deepgram, Soniox, ElevenLabs, OpenRouter, self-hosted OpenAI-compatible endpoint) | the provider you selected, authenticated with your key | while the selected route is in use |
| Agent (Claude Code / Codex CLI) | the CLI you installed talks to its own provider under your own subscription | when you press the agent hotkey |
| Google search hotkey | a `google.com/search` URL opened in your browser | when you press Right Option |
| Sparkle updates | GitHub Releases (`appcast.xml` and the DMG) | hourly check, download only on your click |

Each provider has its own data-use terms; check them before pasting a key.
Several providers train on API traffic unless you opt out in their dashboard.

## Permissions

- Accessibility: global hotkeys (hold Space, Right Command) and detecting an
  editable text field before recording.
- Microphone: dictation and meetings.
- System Audio Recording: the other side of a call, only while a meeting is
  being recorded. The audio tap is created at recording start and torn down
  at stop.
- Post Event (part of Accessibility on current macOS): the synthetic
  Command-V used to paste.

The hold-Space detector reads keyboard events only to recognise the trigger
key and Escape. Key contents are never logged or stored.
