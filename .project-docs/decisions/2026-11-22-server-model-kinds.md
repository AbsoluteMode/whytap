---
id: server-model-kinds-2026-11-22
type: decision
title: A user's server offers speech models to speech pickers and language models to text pickers
summary: A self-hosted OpenAI-compatible server's models are sorted by name into speech, language or neither (embeddings, rerankers, voices), and each server has a manual "Offer models for" choice (By model name, Language models, Speech recognition, Both) that overrides the guess; routes already on a server model keep working.
status: stale
tags: [settings, models, server, self-hosted, ollama, routing]
canonical_for: [historical-server-model-name-sorting]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer, through the orchestrating session (ORCH-TASK 66), reported that every model of a self-hosted server appeared in every picker (a company Whisper among LLMs, Ollama's qwen3:0.6b among speech models) and chose "by name plus a manual switch" with LLM / Speech / both, automatic by name by default.
    confirmed_at: 2026-11-22
  - type: commit
    reference: 6a9fda14a39040b46ae7164799e77ac9967fe50e:Sources/Sidekey/AIRouting/ServerModelKinds.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelStatusResolver.swift
    confirmed_at: 2026-11-22
related: [2026-10-19-api-and-models.md, 2026-11-22-direct-model-list-prices.md, 2026-11-22-server-explicit-models.md]
---

# A user's server offers speech models to speech pickers and language models to text pickers

Superseded the same day by [explicit server models](2026-11-22-server-explicit-models.md):
the user adds each model with its type, and names only preselect it. The text
below records the name sorting of build 1704 and is not current guidance.

## Context

`/v1/models` on a self-hosted server (Ollama, vLLM, LM Studio, LiteLLM, a
company gateway) lists IDs only. `ModelCatalogFetcher.parseServer` stored
them with `uses = nil`, which `ModelStatusResolver` reads as "fits every
use", so each server model appeared in every picker the server kind can
serve: a company Whisper among the text models of Drop Smart cleanup and
Meeting notes, Ollama's `qwen3:0.6b` among the speech models of Drop and
Meetings. OpenAI's own list had the same problem and is solved by a name
heuristic in `parseOpenAI`.

## Decision

- `ServerModelClassifier` sorts an ID by name, case-insensitively, into
  speech (`whisper`, `transcri…`, `parakeet`, `canary`, `wav2vec`,
  `conformer`, `sensevoice`, `voxtral`, `moonshine`, `gigaam`,
  `speech-to-text`, and the words `stt`, `asr`, `ctc`, `rnnt`, `tdt`,
  `vosk`), other (`embed`, `rerank`, `text-to-speech`, `diffusion`,
  `dall-e`, `moderation`, and the words `tts`, `xtts`, `kokoro`, `piper`,
  `bark`, `bge`, `gte`, `minilm`, `clip`, `sdxl`, `e5`) or language
  (everything else). Other is checked first. A word is a run of letters and
  digits, so `mistral-nemo` is not `ctc` and `speechless-llama` is a
  language model.
- Speech models serve `realtimeSTT` and `asyncSTT` (the server's realtime
  socket and `/v1/audio/transcriptions` alike); language models `chat` and
  `chatWithTools` (the Agent still has no server route); other models
  nothing. `parseServer` stores this guess in the catalog.
- Each server has `modelKinds` (`ServerModelKinds`): By model name
  (`automatic`, the default), Language models, Speech recognition or Both.
  It is a popup "Offer models for" in the server's form under API keys.
  The resolver applies it to every model of that server, so it wins over
  the guess and also sorts catalogs cached before this change. Both offers
  every model, including embeddings, as before this change.
- The model a feature already runs on is not judged by the guess or the
  choice: its row status, its place in that feature's picker and a re-pick
  stay as they were. Only the user moves a route. Other features of the same
  server are offered by kind.
- A server section that has no model of the feature's kind (or no list at
  all) takes a typed model name, as servers without `/models` already did:
  a server may serve models it does not list. A typed name the catalog lists
  under another kind is refused with the reason ("not a speech model",
  "not a text model"); the choice fixes a wrong guess.
- Storage: one optional field of the server in the routing document
  (`sidekey.aiRouting.v1`), written only when it is not automatic, so an
  untouched server stores exactly what it did. Backup and settings sync
  carry the routing document as before; no new key or file. An older build
  ignores the field (its decoder skips unknown keys) and drops it on its
  next save; a value from a newer build reads as automatic rather than
  dropping the server (backup validation decodes every server strictly).

## Why

Maxim chose "by name plus a manual switch". Names are the only metadata
every OpenAI-compatible server shares, and the common families are
recognizable. A wrong guess must never cost the user a working setup, hence
the per-server override and the untouched routes. Unknown names default to
language models because that is what such servers mostly host.

## What was checked

- `ServerModelKindsTests`: whisper-large-v3 plus qwen3:0.6b gives Speech
  only whisper and Text only qwen across Drop Fast/Smart, Meetings, Agent
  voice, Voice search, Smart cleanup, Meeting notes and Translation, with
  cross-kind picks refused; 39 real model names (Ollama tags, Hugging Face
  repos, gateway aliases) sorted correctly; an unknown name is a language
  model, embeddings and voices go nowhere; Both, Speech, Language and back
  to automatic; empty `/v1/models` takes typed names for either kind;
  five broken bodies throw `.malformed`; routes on a model now sorted
  elsewhere keep status, selection and re-pick, also after an explicit
  choice excludes them; the choice survives a reload, is absent for
  automatic, keeps the backup's server key account, and older/newer
  documents keep their servers.
- Live: Whytap's own fetcher and resolver against Ollama on
  `localhost:11434` (`qwen3:0.6b`): automatic and Language offer it only to
  text features, Speech only to speech features, Both to all. The installed
  app was not touched.

## Rejected

- Probing each model to learn its kind: a paid or slow request per model and
  per server, and Invariant 1 allows probes only on pick or Check now.
- Ollama's `/api/show` capabilities: Ollama only, and speech servers rarely
  run there.
- A per-model toggle: many rows to maintain for a rare wrong guess; the
  per-server choice covers mixed servers well enough with typed names.
- Re-checking routes against the new sorting and marking them "not
  supported": would silently break dictation that worked yesterday.
- A separate defaults key for the choice: would need its own backup and sync
  entries; the server record already travels everywhere.

2026-11-22 · branch `claude/selfhosted-model-kinds-97b7cb`
