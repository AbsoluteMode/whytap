# Meeting Assistant: a decision model gates the answer model

## Context

On 2026-10-27 the Costs journal showed 558 Claude Sonnet 5.5 requests ($4.45 via
OpenRouter) for one 70-minute meeting on 2026-10-26. The pilot (#230) sends the
retained transcript to the answer model every 4 seconds whenever any word changes.
On 2026-10-19 the user and Codex had agreed on a cheap detector that watches new
utterances and calls the strong model only when help is needed; the pilot shipped
without it. The user asked to restore that design: Jev checks the other
participants' new speech, and only a positive decision sends context to Sonnet.

## Decision

- A new optional route, **Meeting Assistant detector** (Decision mode), starts unset.
  Allowed models: OpenRouter `typesafe/jev-1.14` and OpenAI `gpt-6-luna`.
- With a detector set, a 10-second timer checks only unchecked finals (at most
  1,500 characters), 500 preceding characters and the last three offered questions.
  The Jev predicates `needs_help` and `already_handled` are the 2026-10-19 wording.
- The answer model is called only at `needs_help >= 0.5` and `already_handled < 0.5`.
  It then extracts questions exactly as before, from the same transcript.
- A malformed verdict shows a warning and keeps listening, without a paid retry.
  An HTTP or connection failure stops listening visibly. There is no fallback to the
  answer model and no provider substitution.
- Unset keeps the previous 4-second behavior. Speech is never sent to a decision
  model that the user did not choose.
- An optional route left unset is not flagged as missing setup. The Costs journal
  records it under its own feature ID.

## Why

The replay data from 2026-10-19 (one recorded 30-minute meeting, 136 checkpoints,
13 labelled positive checkpoints, 8 help events) is stored with probabilities for
both models. Recomputed offline, with no new requests:

| Model | Threshold | Gate opens | Events covered |
| --- | --- | --- | --- |
| Jev 1.14 | 0.75 (experiment) | 12 / 136 | 6 / 8 |
| Jev 1.14 | **0.5** | 29 / 136 | 7 / 8 |
| Jev 1.14 | 0.3 | 52 / 136 | 7 / 8 |
| gpt-6-luna | **0.5** | 28 / 136 | 7 / 8 |

In this design a false positive costs only one answer-model call, and that model
still returns no question when there is none. Recall therefore matters more than
precision. At 0.5 the gate keeps about a fifth of the checks and reaches 7 of 8 events.
- Detector cost: Jev cost about $0.009 per 30 minutes in the replay (OpenAI was
  about twice that).
- Expected answer-model calls: about 58 per hour instead of about 480.
- Expected cost: roughly $0.5 per hour instead of about $3.9, at the measured
  per-call prices.

## What we tested

Unit and flow tests with fake audio and stubbed HTTP cover:
- the request shape and bounds;
- thresholds and repeat suppression;
- malformed and duplicate answers, and uncalibrated models;
- usage under the detector feature;
- routine speech staying with Jev, while a help signal reaches the answer model once;
- only unchecked speech being sent;
- warning versus stop on detector errors;
- an unresolvable route refusing to start;
- the unchanged path without a detector.

Limitations:
- The thresholds come from one in-sample meeting with subjective labels. They
  are not held-out validation.
- The replay used timestamped 30-second windows; the app uses character windows
  over finals.
- No live meeting was run.

## Rejected

- The refined 2026-10-19 predicate at 0.75: Jev fell to 2 of 8 events.
- Making the detector required: it would silently send speech to a new provider
  and break existing setups.
- Falling back to the answer model when the detector fails: it would hide failures
  and bring back the cost.
- Lowering the interval or sending only deltas to Sonnet without a detector: this
  is what the user asked to replace.

2026-10-27
