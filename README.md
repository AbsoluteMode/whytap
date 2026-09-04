# Whytap

Voice input and a voice-driven agent for macOS, running entirely on your Mac.

Hold **Space** in any text field, speak, release: the transcript is pasted
where the cursor is. Tap **Right Command** to ask your local coding agent
(Claude Code or Codex CLI) a question by text, hold it to ask by voice. Let
Whytap notice your meetings and turn them into notes. All of it without an
account, without Whytap servers and without telemetry.

Whytap is free and open source (MIT). See `LICENSE`, `TRADEMARK.md` and
`THIRD_PARTY_LICENSES.md`.

## Download

Grab the latest universal DMG (Apple Silicon + Intel) from the
[Releases page](https://github.com/AbsoluteMode/whytap/releases/latest)
(`Whytap-latest.dmg`), drag **Whytap** into **Applications** and launch it
from Spotlight. Updates arrive through Sparkle from the same Releases page.

Requirements: macOS 14.2 (Sonoma) or newer. Local speech and text models
need Apple Silicon; on Intel Macs use your own provider key instead.

## What runs where

| Feature | Route | Runs on |
|---|---|---|
| Dictation (Drop) | Local model: FluidAudio Parakeet TDT v3 (Core ML) | your Mac, offline after a one-time download |
| Dictation (Drop) | Your key: OpenAI Realtime, Deepgram, Soniox, ElevenLabs, or any self-hosted OpenAI-compatible endpoint | the provider you chose, with your key |
| Smart cleanup of dictated text | Local model: Qwen3-4B on MLX | your Mac |
| Smart cleanup of dictated text | OpenRouter with your key, or a custom OpenAI-compatible endpoint (Ollama, LM Studio, vLLM) | the endpoint you chose |
| Agent (Right Command) | Claude Code or Codex CLI installed on your machine, your subscription | your Mac plus the CLI's own provider |
| Meeting Notes | Local: Parakeet + FluidAudio diarization + MLX summary, or your key | your Mac, or the provider you chose |

Keys you enter are stored in the macOS Keychain and sent only to the
provider you selected. Transcripts, notes and history are SQLite files under
`~/Library/Application Support/`.

## First run

1. Grant **Accessibility**, **Microphone** and (for Meeting Notes) **System
   Audio Recording** when prompted. Accessibility is what lets the hold-Space
   gesture and the agent hotkey work globally.
2. Pick where speech is transcribed in **Settings, Models**: download the
   local model (Apple Silicon) or enter a provider key.
3. Hold Space in any text field and talk.

The Dynamic Island at the top of the screen is the whole UI. There is no
menu bar item; open Settings from the island or with the Settings hover
button.

## Hotkeys

| Action | Default |
|---|---|
| Dictate into the focused field | hold Space |
| Ask the agent by text / by voice | tap / hold Right Command |
| Google the selection or your voice | tap / hold Right Option |
| Record a meeting now | Option M |
| Hover buttons 1 to 5 | Option 1 to Option 5 |
| Close the agent answer | Escape |

Everything is remappable in **Settings, Hotkeys**. The Help window lists the
full set.

## Building from source

```bash
git clone https://github.com/AbsoluteMode/whytap.git
cd whytap
swift build
swift test
./scripts/dev-run.sh --run
```

Use `scripts/dev-run.sh` instead of `swift run`: it signs the dev bundle with
a stable ad-hoc identity so the permission grants survive rebuilds. Release
packaging (signing, notarization, Sparkle appcast, GitHub Release) is
described in `docs/build-and-release.md`. The Metal library for MLX is
committed (`Resources/mlx.metallib`) and pinned to the resolved `mlx-swift`
revision; bump both together with `scripts/build-metallib.sh`.

Architecture notes live in `CLAUDE.md`, the product spec in `docs/SPEC.md`,
hotkey conventions in `docs/hotkey.md`, and the reasoning behind
non-obvious choices in `docs/decisions/`.

## Contributing

See `CONTRIBUTING.md`. Bug reports and pull requests are welcome; proposals
that would require a Whytap-hosted service are out of scope by design.

## Security

See `SECURITY.md`. Report vulnerabilities to security@whytap.ai.
