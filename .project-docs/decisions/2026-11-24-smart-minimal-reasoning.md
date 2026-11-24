---
id: smart-minimal-reasoning-2026-11-24
type: decision
title: Drop Smart asks direct Anthropic and OpenAI models for the least reasoning
summary: On the direct Anthropic and OpenAI routes Drop Smart cleanup sends the lowest reasoning setting the chosen model accepts and turns thinking off where the model allows it; a model outside the tables gets no field, a refused field is dropped and the request repeated, and the cleanup timings are logged at the default level so the system log keeps them. OpenRouter, custom servers, translation and meetings are unchanged.
status: confirmed
tags: [smart, dictation, latency, reasoning, effort, anthropic, openai, diagnostics]
canonical_for: [smart-direct-reasoning]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: "On 2026-11-24 the maintainer reported a Smart dictation that waited about 46 seconds instead of the usual 1 to 4 and asked that Smart, an exact task that needs no long reasoning, pass the minimal available reasoning to OpenAI and Anthropic, or a zero reasoning budget where possible (orchestrator task 92)."
    confirmed_at: 2026-11-24
  - type: url
    reference: https://platform.claude.com/docs/en/build-with-claude/effort
    confirmed_at: 2026-11-24
  - type: url
    reference: https://developers.openai.com/api/docs/guides/reasoning
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/SmartDirectReasoning.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Tests/SidekeyTests/SmartMinimalReasoningTests.swift
    confirmed_at: 2026-11-24
related: [2026-09-07-smart-latency.md, 2026-11-23-agent-low-effort.md]
---

# Drop Smart: minimal reasoning on direct routes

## Context

Smart cleanup makes one request to the model the user chose and pastes the
answer; the user waits for it after releasing the key. Since
[2026-09-07](2026-09-07-smart-latency.md) the OpenRouter route asks for the
lowest reasoning effort the catalog lists. The direct Anthropic and OpenAI
routes, added later, sent no reasoning setting, so every model ran at its
default: high effort with adaptive thinking on Claude Sonnet 5.5 and Fable,
medium on Claude Opus 5.5, Haiku 5.5 and the current OpenAI reasoning models.

On 2026-11-24 a Smart dictation of 8 seconds of speech (70 characters) on
`anthropic` / `claude-sonnet-5-5` waited about 46 seconds, and a later one
about a minute, against the usual 1 to 4. The maintainer asked whether Smart
ran with long reasoning and asked for the minimum.

Reasoning was not the cause of those two waits. The system log of the running
app (CFNetwork lines, default level) shows that Anthropic answered both
requests in 2.6 to 2.8 seconds. The Mac sends its traffic through a local
system proxy (127.0.0.1:7897), and for about a minute each time that proxy
opened no new outbound connection: the first Smart request went to an idle
connection that was already dead and failed after 9 seconds with "network
connection lost" (a POST is not resent by the system), the island showed
"Smart unavailable" with Retry, and the retried request waited 31 and 9
seconds for the proxy before it was sent. In the second case the live
ElevenLabs stream stalled the same way (the session stopped the take after
12 seconds without progress) and the batch upload of the retained audio never
connected within its 30-second deadline. The app's own timing lines were
missing from that log because they were written at the info level, and the
direct Anthropic path wrote none.

The request stands on its own: without a setting the models do reason on this
task (16 to 640 reasoning tokens per dictation on OpenAI, see the table
below), and that time is spent on every dictation.

## Decision

- **Scope.** Only Drop Smart cleanup (`PostProcessor`, client profile
  `.smart`) on the direct Anthropic and OpenAI routes. OpenRouter keeps the
  catalog policy, a user's own server gets no reasoning field whatever its
  model is called, and translation (profile `.dictation`) and meetings
  (`.standard`) send what they sent before. The model and the provider are
  never changed.
- **Anthropic Messages** (`SmartDirectReasoning.anthropic`):
  - `output_config: {effort: "low"}` on the models of Anthropic's effort page,
    the same list the Agent uses (`NativeAgentEffort.anthropicSupports`).
  - Thinking off where the model has a setting for it: Claude Sonnet 5.5 gets
    `thinking: {type: "between_tools"}` (it refuses `disabled`, and
    `between_tools` takes no other field); Claude Haiku 5.5 and Claude Sonnet 5
    get `thinking: {type: "disabled"}`.
  - Fable, Mythos and Claude Opus 5.5 cannot turn thinking off: low effort
    only. Claude Opus 5 accepts `disabled`, but Anthropic warns that it then
    may write thinking tags into its visible text, which Smart would paste:
    low effort only. Opus 4.5 to 4.8 and Sonnet 4.6 do not think unless asked:
    low effort only. Sonnet 4.5, Haiku 4.5 and older refuse `effort` and do
    not think unless asked: no field.
- **OpenAI Chat Completions** (`SmartDirectReasoning.openAIEffort`,
  `reasoning_effort`), by what each model accepted on 2026-11-24:
  - `none`: GPT-5.1, 5.2, 5.4 (also mini, nano), 5.5, 5.6 (Luna, Sol, Terra),
    GPT-6 Luna, GPT-6 Sol, GPT-6.1 Terra;
  - `minimal`: GPT-5, GPT-5 mini, GPT-5 nano (they refuse `none`);
  - `low`: GPT-6 Astra, GPT-6.1 Sol, GPT-6.2 Astra, GPT-6.2 Sol and o3 (they
    refuse `none` and `minimal`), and any GPT-5, GPT-6 or o-series model not
    listed above, since every reasoning model takes `low`;
  - no field: GPT-4.1 and GPT-4o (they refuse the argument), chat snapshots,
    pro models and any other generation.
- **A refused field never costs the dictation.** When a request that carried
  one of these fields comes back with HTTP 400 (422 on Anthropic too), the
  same request goes once more without the fields, exactly as before this
  decision. When that repeat returns a valid answer (a decoded, non-empty
  reply, not merely HTTP 200: a proxy can answer 200 with its own page), the
  model gets no field again until the app is relaunched
  (`SmartReasoningRefusals`, memory only). A second
  refusal is the error it was before (a rejected input, or a refused model
  with its badge) and changes nothing for the next dictation. A key
  error, a rate limit, an outage and a connection failure are not repeated.
- **Timings survive.** The numeric lines `cleanup …` (category `cleanup-llm`),
  `drop processing ok …` and `drop turn … completed …` are logged at the
  default level, which the unified system log stores, instead of info. The
  direct Anthropic path now writes the same line (model ID, requested
  setting, HTTP status, milliseconds, output and thinking tokens, whether the
  field was refused), and a failed request writes its status and
  milliseconds. A model name is saved text that a user can type, so it is
  logged only when it is a public catalog name (`CleanupDiagnosticModel`): a
  published Anthropic or OpenAI model name, or an ID that OpenRouter's catalog
  listed at its last read. Any other name, a fine-tuned OpenAI model included,
  is logged as `other`, and a user's own server as `custom`. No text, key, URL
  or error body.
  Read them with the system tool by its full path (in zsh a bare `log` is
  a shell builtin and prints nothing useful):

  ```bash
  /usr/bin/log show --last 2d --predicate 'subsystem == "com.rootwise.sidekey" AND (category == "cleanup-llm" OR eventMessage CONTAINS "drop processing" OR eventMessage CONTAINS "drop turn")'
  ```

## Why

- Smart edits a text it is given; it plans nothing and calls no tools. Both
  providers recommend their lowest setting for latency-sensitive work, and
  the maintainer asked for it.
- The tables hold only what the providers document or a live request
  confirmed, so a known model is not sent a value it refuses. The repeat
  without the field covers a table that went stale: the worst case is one
  short refused request per model and launch, never a failed dictation.
- A setting that the provider's own guide says can put internal tags into the
  visible text (disabled thinking on Claude Opus 5) is not worth the saved
  time when the text is pasted for the user.
- The default log level needs no new file, store or setting, and the lines
  already carried numbers only.

## What was tested

`SmartMinimalReasoningTests`, the real `PostProcessor` and client against a
stubbed provider: Smart on Claude Sonnet 5.5 (low effort, `between_tools`,
unchanged prompt and model); Fable (low effort, no thinking field, the pass
verdict still inserts the dictation unchanged and a thinking block is not
pasted); the per-model table for Anthropic with dated IDs; an older Claude
(request identical to before); OpenAI models at `none`, `minimal` and `low`
and models that get no field; a refused field on each provider (cleaned text,
second dictation sent without the field, no refusal badge); a repeat answered
with a proxy page or an empty reply under HTTP 200 (the dictation fails, the
model is not marked); the stored lines read back from the unified log of the
test process (a private alias, a fine-tuned ID and a name on a user's own
server never appear, on success and on failure, on all three providers); a rejected input,
a refused model, HTTP 401, 429, 500 and 529 and a timeout; OpenRouter
unchanged (catalog effort, throughput sorting, none of the direct fields); a
user's own server named like an OpenAI model; translation and meeting profiles
on direct routes.

Live, OpenAI Chat Completions, 2026-11-24. Which value each of 24 catalog
models accepts was probed with a one-word request (the table above). Then
eight synthetic dictations (clean text, fillers, a self-correction, brand
names, a list, a long thought, a question, English) went through the real
Smart prompt with and without the field:

| Model | Without the field: median, slowest, reasoning tokens | With the field: median, slowest, reasoning tokens |
| --- | --- | --- |
| gpt-5.5 | 2.76 s, 3.62 s, 16 to 126 | `none`: 1.40 s, 2.30 s, 0 |
| gpt-6-luna | 3.07 s, 3.51 s, 28 to 213 | `none`: 1.28 s, 1.70 s, 0 |
| gpt-5-mini | 6.11 s, 8.01 s, 64 to 640 | `minimal`: 1.35 s, 2.11 s, 0 |
| gpt-6.2-sol | 2.19 s, 3.22 s, 0 | `low`: 1.75 s, 2.91 s, 0 |

In every run the clean sentence returned the pass verdict and nothing else
did; fillers and the cancelled variant of the self-correction were removed,
brand names were written canonically, the list became a list and the long
thought kept its paragraphs, its hedges and its "change nothing yet". The
texts differ in wording about as much as two runs of one setting do. Two
differences seen: gpt-5-mini at `minimal` wrote the spoken "about twenty
minutes" with digits and a tilde, and an English dictation sent with the Russian input-language hint
was translated into Russian more often without reasoning (gpt-5.5: 1 of 4 runs
without the field, 3 of 4 at `none`, 2 of 4 at `low`). That hint confusion
exists at every setting and belongs to the prompt, not to this change; it is
left as a follow-up.

Live, Anthropic Messages, 2026-11-24 (the app's `anthropic-version`,
2023-06-01). The Models API states the same table: `between_tools` is
supported by Claude Sonnet 5.5 only, `disabled` by Haiku 5.5, Opus 5, Sonnet 5
and the 4.x models and by no Fable, Mythos or Opus 5.5 model, and `effort` by
every listed model except Haiku 4.5. One Smart request each confirmed that
Haiku 5.5 accepts low effort with `disabled`, and Fable 5.2 and Opus 5.5 low
effort alone. The same eight dictations on the maintainer's route, one request
at a time:

| claude-sonnet-5-5 | Median | Slowest | Total | Thinking |
| --- | --- | --- | --- | --- |
| no field (before) | 1.70 s | 3.14 s | 13.7 s | 2 of 8 replies, 197 and 217 tokens |
| low effort | 1.28 s | 1.93 s | 10.6 s | none |
| low effort, `between_tools` (sent now) | 1.17 s | 1.70 s | 9.3 s | none |

The pass verdict came for the clean sentence only, in all three settings; the
self-correction, the brand names, the list, the long thought with its hedges
and the English dictation (kept in English) came out the same. One difference
seen: with `between_tools` the opening filler of one dictation ("listen,")
stayed in the text.

## Rejected

- Medium or the provider default: the maintainer asked for the minimum.
- `thinking: disabled` on Claude Opus 5: see Why.
- Sending the lowest value to every model and reading the accepted values
  from the provider's error text: an extra request on most first dictations
  and a parser for free-form error messages.
- Reading the Anthropic Models API flag per dictation: the Smart route holds
  only an endpoint and a model, and the catalog flag says nothing about
  `between_tools`.
- Choosing a faster model or provider automatically: the project never
  switches the user's choice.
- A separate timing journal file or new columns in `ai-usage.sqlite`: a new
  store (or a schema change inside the backed-up Costs history) for what the
  system log already keeps for days.
- Streaming the answer or changing the Smart prompt: outside this task.
- Resending a Smart request automatically after "network connection lost":
  it would have saved the manual Retry in both cases above, but it sends a
  paid request twice when only the answer was lost. Left to the maintainer
  as a separate decision.

2026-11-24, branch `claude/smart-minimal-reasoning`; an independent review's finding (a request refused both ways must not mark the model) folded in the same day, and so were the two findings of the builder's review of ticket 508
(an invalid HTTP 200 answer to the repeat must not mark the model; unverified
model names must not reach the stored log).
