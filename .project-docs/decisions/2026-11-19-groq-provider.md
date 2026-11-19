---
id: groq-provider-2026-11-19
type: decision
title: Groq as a built-in provider for text features and Agent
summary: Groq gets its own key tile and runs the text features and the native Agent over its OpenAI-compatible Chat Completions API. Speech is out of scope. The request shape follows Groq's documentation; no request was made with a real key yet.
status: confirmed
tags: [byok, providers, agent, settings, groq]
canonical_for: [groq-provider]
verified_at: 2026-11-19
sources:
  - type: user-confirmed
    reference: On 2026-11-19 Maxim removed Groq from API hints because a hint is useless when its key cannot be used normally, and asked to set Groq up so people can use it.
    confirmed_at: 2026-11-19
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentModel.swift
    confirmed_at: 2026-11-19
  - type: repository
    reference: Sources/Sidekey/AIRouting/ModelCatalog.swift
    confirmed_at: 2026-11-19
  - type: repository
    reference: Tests/SidekeyTests/AIRouting/GroqProviderTests.swift
    confirmed_at: 2026-11-19
related: [2026-10-19-api-and-models.md, 2026-10-22-native-agent.md, 2026-10-19-api-hints.md]
---

# Groq as a built-in provider

## Context

Groq's Free plan needs no card and renews daily, which makes it a useful
no-cost route for a new user. Until now it could only be added as an
"OpenAI-compatible server": the user had to know the address, it could not run
Agent (a custom server never serves Agent), and it had never been tried. The
user decided not to advertise it in API hints in that state.

## Decision

Groq is a provider kind of its own (`AIProviderKind.groq`, account `groq`,
Keychain account `byok.groq.api_key`), with a key tile in Settings -> API &
Models -> API keys.

- **Serves** the text features (Drop Smart cleanup, Meeting notes, Translation,
  Subtitles translation) and Agent. It serves no speech feature and no separate
  decision stage: the same column as Anthropic in the feature table.
- **Host and key**: every request goes to `https://api.groq.com/openai/v1` with
  the Groq key in the Authorization header. Nothing is borrowed from another provider; a
  missing key leaves the feature not set.
- **Key check**: the free `GET /models`, never a generation.
- **Models**: the live `GET /models` list. Groq lists speech, voice and
  moderation models beside text ones with no field that tells them apart, so
  families are left out by name (`whisper`, `tts`, `orpheus`, `guard`,
  `safeguard`, `embed`) and inactive models are dropped. Groq documents tool
  use for every text model it hosts, so all offered models are offered to
  Agent too; each pick still passes the synthetic model check. No model is
  recommended by the app: preview models come and go.
- **Agent wire format**: Chat Completions like OpenRouter (system message
  first, `tool_calls`, `role: tool` results), without OpenRouter's `provider`
  object, `X-Title` header or HTTP-200 error envelope.
  - `max_completion_tokens`, not the deprecated `max_tokens`.
  - `strict` is left out of tool definitions: Groq's pages show it on one model
    and do not say which models accept it; the final answer is validated
    locally either way.
  - `reasoning` from a response is not sent back: Groq returns it but does not
    document it as a request property.
  - The agent asks for at most 2,048 output tokens on Groq (8,192 elsewhere).
    The Free plan allows about 8,000 tokens a minute per model and the
    requested output is assumed to count toward it with the prompt.
- **Text features**: the shared Chat Completions client. A leading
  `<think>…</think>` block in Groq's text is removed before the text is used,
  because without tools Groq's reasoning models may put thinking in the
  content and Drop would paste it. Only thinking, or an unclosed block, is an
  empty answer.
- **Errors**: 413 gets its own fixed message (Groq answers it when one request
  exceeds the per-minute tokens); 429 keeps the shared "busy or usage limit"
  message. Provider text is never shown or logged.
- **Costs**: Groq reports tokens, not a charge. Calls are recorded without a
  price; no rate table is invented.
- **Backup**: the Groq key is one of the exported credential accounts.
- **Older builds**: a rollback build does not know the `groq` account. Its
  lenient routing reader skips such a route, which then reads as not set there;
  nothing else in the routing document is lost.

API hints lists Groq again under Language models, with the per-minute limit in
its details.

## Why

A provider with its own tile is what "the key can be used" means in this app:
one paste, a checked key, models in the picker, Agent included. Reusing the
custom-server path would keep the address ritual and exclude Agent.

Conservative choices (no `strict`, no reasoning replay, a small output cap)
were taken wherever Groq's documentation is silent, because a rejected request
is worse than an unused optional feature.

## What was tested

- 13 scenario tests with a stubbed network (`GroqProviderTests`): account and
  Keychain separation, feature table, catalog filtering and malformed answers,
  key check outcomes, text features only with Groq's own key, text request
  shape, thinking removal, Agent request shape, tool step pairing, 401/413/429
  messages without retry or provider text, no request without a key.
- Full `swift test`.
- **Not tested: any request with a real Groq key.** No key was available in
  Case. Unknown until then: whether the listed models accept the request as
  sent, how often the Free per-minute limit stops a multi-step Agent turn, and
  whether requested output really counts toward that limit.

## Known limit

The agent never repeats a model request by itself. On the Free plan a turn
with several tool steps can exceed the per-minute tokens and end with the
"busy or usage limit" message. Waiting for Groq's `retry-after` and sending the
refused request again would not repeat a paid call or an action, but it changes
the agent's no-retry rule and was not done without the user's decision.

## Rejected

- **Keep Groq as a custom server and document the address**: no Agent, manual
  setup, the reason the hint was removed.
- **Groq Whisper for dictation**: it transcribes finished recordings; Whytap's
  speech routes are real-time adapters. A separate piece of work.
- **Cloudflare Workers AI in the same change**: needs an account ID in the
  address besides the token; not asked for.
- **A recommended Groq model**: the list changes and half of it is preview.
- **Estimating Groq costs from tokens**: no price source the app already trusts.

2026-11-19. PR: see the pull request that adds this file.
