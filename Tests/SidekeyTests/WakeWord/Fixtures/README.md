# Wake word test fixtures

- `light-up.wav`: `test_wavs/0.wav` from the keyword-spotting model archive
  (see `Resources/WakeWord/README.md`), a LibriSpeech utterance (CC BY 4.0)
  containing "light up". 16 kHz mono PCM16.
- `sentencepiece-reference.json`: phrase -> tokens produced by SentencePiece
  0.2.3 with the model's `bpe.model`, the reference for `WakeWordTokenizer`.
