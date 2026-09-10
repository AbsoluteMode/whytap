---
id: onboarding-models-2026-09-10
type: decision
title: Configure provider keys directly in onboarding
summary: Add speech and optional Smart setup before the first dictation, sharing the existing Settings implementation.
status: confirmed
tags: [onboarding, byok, keychain, models, local]
canonical_for: [onboarding-model-setup]
verified_at: 2026-09-10
sources:
  - type: user-confirmed
    reference: User request in the 2026-09-10 Whytap task to add API-key entry directly to onboarding.
    confirmed_at: 2026-09-10
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingModelsScreen.swift
    confirmed_at: 2026-09-10
  - type: repository
    reference: Sources/Sidekey/Settings/SettingsModelsViewModel.swift
    confirmed_at: 2026-09-10
related: [../project.md]
---

# Provider setup in onboarding

## Context

New users previously reached Try Drop immediately after granting permissions.
Keys and model downloads were available only in Settings, so dictation could
be unconfigured when the tour asked them to try it.

## Decision

Insert a resumable Models step between Permissions and Try Drop. It presents
speech setup followed by optional Smart text processing. Reuse the Settings
provider fields, masked API-key inputs, connection validation, Keychain stores
and local model downloads. Show Your key first; Local remains available on
supported hardware. Selecting a presentation route does not persist it.

Save & continue advances only after connection validation and credential
persistence succeed, or after the chosen local model is ready and connected.
Do not report success when Keychain writes fail. The form and navigation are
disabled during saves; leaving the screen cancels its continuation task.
Never put keys in onboarding resume state or logs.

Set up later on the speech page goes to Skills, bypassing an unconfigured
dictation exercise. Skipping the optional Smart page goes to Try Drop and
does not change the user's existing Smart configuration. Back from Try Drop
returns to Models. Missing permissions still take priority on relaunch.

## Alternatives

Opening a separate Settings window would interrupt the first-run flow.
A second key-storage and provider-validation implementation would diverge
from the existing model setup and error handling.

## Rationale

The user asked to enter keys during onboarding. Reusing the existing model
forms keeps providers, local alternatives and credential storage consistent.

## Sources

The dated user request and implementation files listed above.

## Comments and objections

No objections were recorded.

## Resolution

Keep credential setup inside onboarding, before the first live dictation.

## Consequences

Onboarding has one additional resumable step with two setup pages. Smart
configuration remains optional, and a user can postpone all model setup.
Keychain failures are also surfaced when saving through Settings.

## Supersedes / superseded by

Supersedes the direct Permissions-to-Try-Drop transition. No later decision
is known.
