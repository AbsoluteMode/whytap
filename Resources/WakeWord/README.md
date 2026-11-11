# Wake word model

Keyword-spotting model for the opt-in wake word (Settings -> Other).

- Model: `sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01` (English,
  open vocabulary, 3.3M parameters, int8), trained with icefall on GigaSpeech.
- Source: https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2
  (archive SHA-256 not recorded upstream; files below are copied unchanged,
  renamed from `*-epoch-12-avg-2-chunk-16-left-64.int8.onnx`).
- License: Apache License 2.0 (the model card in the archive).

| File | SHA-256 |
| --- | --- |
| `encoder.int8.onnx` | `1e721676515bcd42a186979733981213c66c80db680e1cc582dfedf3be76e678` |
| `decoder.int8.onnx` | `e40ff43297abe815e8898494c17e71bba2152d9d40fa3eb803f75d0f7533329a` |
| `joiner.int8.onnx` | `eae9da0c7e1e6c6a3f4cc42d167899c388f6c6701b94cb96320e4f55df79624c` |
| `tokens.txt` | `fd2ded4050a55d2b1578870ba8697d02371980217806b7558bd0a5cc60f3ba53` |
| `bpe.model` | `c8a2a0129c4ab8e463164c142f82d25649661b122c8cd0b7aab5c9e80b90ad24` |

WHY: .project-docs/decisions/2026-11-11-wake-word.md
