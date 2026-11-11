# Third-party software and assets

Whytap is distributed under the MIT License (`LICENSE`). The application
bundle also contains, or is built with, the following third-party work.
Each component keeps its own license; the full texts ship inside the
resolved packages (`.build/checkouts/<package>/LICENSE`) and, for vendored
files, next to the files themselves.

## Swift packages (resolved through `Package.swift`)

| Package | Use | License |
|---|---|---|
| sparkle-project/Sparkle | in-app updates | MIT |
| FluidInference/FluidAudio | Silero VAD for the meeting detector (Core ML) | Apache-2.0 |

## Vendored and generated binaries

- `Resources/MediaRemoteAdapter/`: runtime artifacts of ungive/mediaremote-adapter.
  License: BSD-3-Clause. See `Resources/MediaRemoteAdapter/THIRD_PARTY_NOTICE.md`
  for the pinned commit and full text.
- `Resources/blocknote/`: the meeting-notes editor bundle built from
  `scripts/blocknote-src/` with Vite. It contains BlockNote (`@blocknote/core`,
  `@blocknote/react`, `@blocknote/mantine`, MPL-2.0), Mantine (MIT), React and
  ReactDOM (MIT), ProseMirror and TipTap (MIT) and their transitive
  dependencies. The MPL-2.0 parts are used unmodified; their source is
  available from the upstream BlockNote repository.

## Models downloaded at runtime

Whytap does not bundle model weights. The meeting detector downloads, on its
first speech check, the Silero VAD Core ML conversion published by
FluidInference on Hugging Face (`FluidInference/silero-vad-coreml`; the
upstream Silero VAD is MIT). On-device speech recognition, diarization and
LLM models were removed.

Check the model card on Hugging Face for the exact terms.

## Fonts

- Instrument Serif (`Resources/Fonts/InstrumentSerif-*.ttf`), SIL Open Font
  License 1.1, see `Resources/Fonts/OFL.txt`.
- Playfair Display (`Resources/Fonts/PlayfairDisplay-*.ttf`), SIL Open Font
  License 1.1, see `Resources/Fonts/PlayfairDisplay-OFL.txt`.

## Logos

`Resources/UsefulLinkIcons/` holds logos of third-party products used to
label those products inside the app. They remain the trademarks of their
owners and are not licensed under the MIT License. See `TRADEMARK.md`.

## Agent and dashboard integrations

- OpenCode is downloaded from the official
  [anomalyco/opencode releases](https://github.com/anomalyco/opencode/releases)
  only after an explicit installation action, or discovered from the user's
  existing installation. Its source is MIT-licensed; it is not bundled in the
  Whytap source or application. See the
  [OpenCode license](https://github.com/anomalyco/opencode/blob/dev/LICENSE).
- Monitor's passive dashboard format is compatible with
  [AbsoluteMode/easy-monitoring](https://github.com/AbsoluteMode/easy-monitoring).
  Copyright (c) 2026 AbsoluteMode; MIT. The original notice is retained in
  [docs/licenses/ez-monitor-MIT.txt](docs/licenses/ez-monitor-MIT.txt).
