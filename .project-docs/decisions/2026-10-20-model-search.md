---
id: searchable-model-picker
type: decision
title: Search models by family and size
summary: Replace the long model menu with a native searchable popover matching independent query terms.
status: confirmed
tags: [settings, models, search, keyboard]
canonical_for: [model-picker-search]
verified_at: 2026-10-20
sources:
  - type: user-confirmed
    reference: On 2026-10-20 the user requested a normal search field in model selection and gave qwen 27 as an example that should keep matching.
    confirmed_at: 2026-10-20
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/ModelPicker.swift
    confirmed_at: 2026-10-20
related: [2026-10-21-provider-key-tiles.md, 2026-11-17-openrouter-model-prices.md, 2026-11-20-elevenlabs-scribe-v3.md]
---

## Context

The native menu lists the entire compatible catalog. Finding a model requires
scrolling, and menu type-ahead cannot filter independent family/size terms.

## Alternatives

Keep native menu type-ahead; add a separate search sheet; use an anchored
searchable popover. The first retains the reported problem; a sheet separates
the choice from its feature row.

## Decision

Use an anchored native popover with NSSearchField, grouped filtered results and
fixed recovery actions. Reuse the shared compact popup label. Match every term
in any order, splitting letters/digits and ignoring case and punctuation.
Keep exact account/model identities and the existing verified selection path.

## Rationale

A remembered family and size locate an ID without requiring its punctuation or
version. Native editing preserves IME and standard text shortcuts. Search state
belongs to the open picker and does not persist as a route preference.

## Sources

The dated request above and the repository implementation/tests.

## Comments and objections

None recorded. Typo tolerance and alias catalogs were not requested.

## Resolution

Implement the requested search. Live focus, VoiceOver and popover acceptance
remain separate from offscreen renders and isolated command tests.

## Consequences

The model control opens a popover; other selection controls keep native menus.
Catalog refresh must notify the open picker even when selected rows stay equal.

## Supersedes/superseded by

Footer actions are superseded by
[automatic model refresh](2026-10-21-provider-key-tiles.md); search remains.

No prior decision is superseded in full. The model control is the exception to
the native-menu portion of the compact selection-menu decision.
