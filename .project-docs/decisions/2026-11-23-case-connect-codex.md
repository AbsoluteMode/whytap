---
id: case-connect-codex
type: decision
title: Case Connect offers Codex; Whytap Agent wears the Agent orb
summary: The Connect catalog is Whytap Agent, Claude Code, Codex and Cursor; the Whytap Agent row shows the island's Agent orb instead of the OpenCode mark.
status: confirmed
tags: [case, secrets, agents, connect, codex, icons]
canonical_for: [case-connect-catalog]
verified_at: 2026-11-23
sources:
  - type: user-confirmed
    reference: On 2026-11-23 the user saw only Whytap Agent and Claude Code in Case → Connect, asked where OpenAI was and asked to replace the Whytap Agent logo; offered the Agent orb, the Whytap app icon or a white sparkle, the user chose the Agent orb.
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/Case/Clients/CaseClientSetup.swift
    confirmed_at: 2026-11-23
  - type: repository
    reference: Sources/Sidekey/DynamicIsland/IslandCaseConnectedApps.swift
    confirmed_at: 2026-11-23
related: [2026-10-21-case-connect-claude-code.md]
---

# Case Connect offers Codex; Whytap Agent wears the Agent orb

## Context

Since 2026-10-21 the Connect catalog was `[.builtInOpenCode, .claudeCode,
.cursor]`. Codex was left out only because that request named Claude Code
alone. Everything else for Codex already shipped: the known client and its
Developer ID identity, `CodexCaseConnector` (`codex mcp add whytap`), the
broker's known-AI entry, the bundled `codex` mark and its blue highlight, and
onboarding already asks about Claude Code and Codex. A user with Codex
installed therefore saw no OpenAI row in Connect.

The Whytap Agent row still showed the OpenCode mark (a white square with a grey
rectangle) from the time the built-in agent ran OpenCode. The agent is now
native and is named Whytap Agent, so the mark pointed at another product.

## Decision

- The catalog is `[.builtInOpenCode, .claudeCode, .codex, .cursor]`, in that
  order. Codex appears only when `CodexBinaryLocator` finds the CLI and it is
  not registered yet, exactly like Claude Code. No connector, identity or
  broker rule changes.
- The empty picker says "Install Claude Code, Codex or Cursor, then open
  Connect again." It no longer names OpenCode, which a user cannot install to
  make a row appear.
- Wherever Case draws a client mark (Connect rows, the rights-screen header,
  the connected-apps strip) Whytap Agent shows `orb-icon-agent`, the same
  coloured orb the island and Toolbox use for Agent, drawn at 1.6x the slot
  because its glow fills the canvas. If the PDF is missing it falls back to
  the `sparkle` symbol the island ticker uses for Whytap Agent. Outside
  clients keep their monochrome template marks.
- The stored identity `.builtInOpenCode` and the case name stay: they are a
  vault compatibility contract.

The key approval card shows a key glyph and the app name, not a client mark,
so it needed no change.

## Rationale

Codex was hidden by one catalog entry while its whole path was built and
tested; the user expects every supported harness in one list. The orb is the
only existing artwork that already means "Agent" in Whytap, so no new asset is
added and the row matches the island.

## What was tested

- Discovery over all sixteen installed/absent combinations of Whytap Agent,
  Claude Code, Codex and Cursor: only installed clients, in catalog order, no
  command run and no file written.
- The picker offers Claude Code and Codex until each is registered and changes
  no saved rights while listing.
- Whytap Agent resolves to the coloured, non-template orb; the other rows
  resolve to bundled marks with visible artwork at 22 pt.
- Offscreen picker renders at 310/390 pt with the four rows and a Codex-only
  row.

No live app check: feature sessions must not launch the app.

## Alternatives rejected

- The Whytap app icon for Whytap Agent: offered, the user chose the orb.
- A white `sparkle`: offered; it matches the monochrome rows but says nothing
  about Whytap.
- Tinting the orb as a template mark: its shape is a blurred disc and loses
  the ring.
- Removing the now unused `opencode.pdf`/`.svg`: left for a separate cleanup.

## Supersedes / superseded by

Supersedes the catalog and the "Codex is not offered" rule of
[Case Connect offers Claude Code again](2026-10-21-case-connect-claude-code.md);
its Claude Code locator notes still hold.

Dated 2026-11-23.
