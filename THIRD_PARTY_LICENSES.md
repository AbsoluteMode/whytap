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
| FluidInference/FluidAudio | Silero VAD, Parakeet speech recognition, speaker diarization (Core ML) | Apache-2.0 |
| ml-explore/mlx-swift | on-device inference runtime | MIT |
| ml-explore/mlx-swift-lm | LLM loading, chat session, Hugging Face download | MIT |
| huggingface/swift-transformers | tokenizers for the local LLM | Apache-2.0 |
| huggingface/swift-huggingface | Hugging Face Hub client | Apache-2.0 |
| huggingface/swift-jinja | chat template rendering | Apache-2.0 |
| mattt/EventSource | server-sent events parsing | MIT |
| ibireme/yyjson | JSON parsing (transitive) | MIT |
| apple/swift-nio, swift-crypto, swift-asn1, swift-atomics, swift-collections, swift-numerics, swift-system | transitive dependencies of the packages above | Apache-2.0 |

## Vendored and generated binaries

- `Resources/mlx.metallib`: Metal kernels compiled from ml-explore/mlx-swift at
  the revision recorded in `Resources/mlx.metallib.revision` with
  `scripts/build-metallib.sh`. License: MIT (ml-explore).
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

Whytap does not bundle model weights. On first use it downloads, with your
consent, from Hugging Face:

- Parakeet TDT v3 Core ML conversion published by FluidInference (CC-BY-4.0
  model weights, Apache-2.0 conversion tooling);
- FluidAudio speaker-diarization Core ML models (Apache-2.0);
- Qwen3-4B-Instruct-2507 4-bit MLX conversion (Apache-2.0, Qwen).

Check the model cards on Hugging Face for the exact terms of each model.

## Fonts

- Instrument Serif (`Resources/Fonts/InstrumentSerif-*.ttf`), SIL Open Font
  License 1.1, see `Resources/Fonts/OFL.txt`.
- Playfair Display (`Resources/Fonts/PlayfairDisplay-*.ttf`), SIL Open Font
  License 1.1, see `Resources/Fonts/PlayfairDisplay-OFL.txt`.

## Logos

`Resources/UsefulLinkIcons/` holds logos of third-party products used to
label those products inside the app. They remain the trademarks of their
owners and are not licensed under the MIT License. See `TRADEMARK.md`.
