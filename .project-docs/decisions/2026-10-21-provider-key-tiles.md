---
id: provider-key-tiles-and-direct-llm
type: decision
title: Provider key tiles and direct OpenAI and Anthropic LLM access
summary: Expand provider squares into checked key forms, offer both direct LLM APIs, and refresh model catalogs automatically.
status: confirmed
tags: [settings, keys, models, openai, anthropic, routing, privacy]
canonical_for: [provider-key-tiles, direct-llm-providers, automatic-model-catalog]
verified_at: 2026-10-21
sources:
  - type: user-confirmed
    reference: On 2026-10-21 the user rejected the technical Keychain helper and requested only Save/Remove, no extra text, and a small Key accepted or Key not accepted notification.
    confirmed_at: 2026-10-21
  - type: user-confirmed
    reference: On 2026-10-21 the user requested square provider tiles that expand into API-key forms, checking that each key works, direct OpenAI and Anthropic LLM support without restricting setup by feature, and removal of Refresh models and Other model ID from the model picker.
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/ProviderKeyTiles.swift
    confirmed_at: 2026-10-21
  - type: repository
    reference: Sources/Sidekey/Streaming/BYOK/AnthropicLLMClient.swift
    confirmed_at: 2026-10-21
  - type: url
    reference: https://developers.openai.com/api/reference/resources/models/methods/list
    confirmed_at: 2026-10-21
  - type: url
    reference: https://platform.claude.com/docs/en/api/overview
    confirmed_at: 2026-10-21
related: [2026-10-19-api-and-models.md, 2026-10-20-model-search.md, 2026-11-19-provider-failure-reasons.md, 2026-11-22-server-window.md, 2026-11-27-compact-key-tiles.md]
---

## Context

The key tab showed only saved-provider chips and left most of the screen empty.
The user requested visible provider squares and rejected unexplained model-list
maintenance actions. Anthropic had previously been limited to the agent.

## Alternatives

Keep chips and a provider dropdown; open a separate sheet from each provider;
or expand a provider square into an inline form. The user selected the inline
form and asked for ordinary OpenAI and Anthropic LLM connections.

## Decision

Show all built-in providers plus a custom-server square and saved servers.
Clicking a tile opens a full-width form below its grid row. One form is open;
Escape or repeating the tile closes it. The grid uses 2/3/4 columns
according to available width and never recreates the form on resize.

Save validates first. As amended later on 2026-10-21, the form has only the key
field and Save/Remove (plus required name/URL fields for custom servers). It has
no helper, persistent form-status/error copy, Check now, Cancel or extra removal
confirmation. Remove is disabled until there is a saved connection. Inline Save
does not open a model-assignment proposal; a panel-level noninteractive notice
shows only Key accepted / Key not accepted for 2.5 seconds, including after the
custom-server form closes. Repeated results restart its lifetime. Models/API hints also route add-key actions to this same minimal surface.
Legacy add-key model methods retain their existing assignment defaults for
callers outside this form.

Invalid, out-of-credit and unreachable checks
keep the previous key and form. Scoped speech keys retain their explicit
limited status. OpenAI requires model-list access before its new key is saved.
Key checking authenticates a provider request; it does not guarantee credit or
access to every inference model. Picking a model retains the separate synthetic
probe. No check uses the user's speech, notes or prompts.

OpenAI and Anthropic serve every LLM mode, including the agent. Direct OpenAI
uses authenticated /models and /chat/completions; Anthropic uses /models and
/messages with the system prompt at the top level. The new OpenAI credential
is byok.openai.llm_api_key, distinct from retired speech credentials. Anthropic
keeps byok.anthropic.api_key. Each request uses only its route's provider key.
The encrypted-backup credential allowlist includes the new OpenAI account.
Adding either key never silently changes a route.

OpenCode receives only the selected provider's environment credential. When
OpenAI's catalog lacks limits, its own model metadata remains authoritative;
the app does not replace it with an empty declaration or substitute a model.
Usage retains the direct provider identity. Direct-provider dollar charges
are unavailable when the response supplies no dollar amount.

Remove Refresh models and Other model ID from the picker footer. Opening the
picker refreshes stale or failed catalogs; successful caches last one day.
An offline refresh retains cached models. A custom server without /models has
a contextual field for its configured model name, through the same probe path.

## Rationale

Provider connections are independent objects and justify visible square
boundaries. Setup and validation belong together. Neither choosing a provider
nor maintaining a catalog should require knowing a feature's internal route.

## Sources

The dated user request, repository paths and official API references above.
Detailed layout and verification limits are in docs/DESIGN.md.

## Comments and objections

Review identified catalog-less custom servers and Anthropic context overflow
as recovery cases. The contextual server field preserves the former; input
errors from Messages do not persist a refusal against an otherwise valid model.

## Resolution

Implement the requested layout and direct APIs with offline transport tests and
native offscreen renders. Real key entry, permissions and physical keyboard/
VoiceOver behavior remain acceptance in the one shared installed application.

## Consequences

Keys remain in the existing Keychain service. Cached catalogs contain metadata
only. Saved routes stay independent. Unsupported OpenAI endpoint families are
excluded from the Chat Completions catalog; the app offers no speech route for
this LLM credential. HTTP errors and incomplete Anthropic output remain errors.

## Supersedes/superseded by

Supersedes the chip layout and Anthropic-agent-only restriction in
[API & Models](2026-10-19-api-and-models.md), and the footer actions in
[model search](2026-10-20-model-search.md). Their route-isolation, search and
verification contracts remain in force.

The 2026-10-21 interaction-feedback requirement applies to provider squares,
form actions and model-picker rows/actions. A local style covers each full hit
target with hover/pressed feedback and preserves keyboard focus. Inherited
disabled state suppresses feedback and dims controls, including busy forms and
unsupported model rows. Shared settings buttons outside this surface are unchanged.
