---
id: server-window-2026-11-22
type: decision
title: A user's server is set up in one window and named by its address
summary: The Custom server tile and each server's tile open one window with the base URL, the optional key and model rows (name, LLM or Transcription, check status); one Save keeps it all. There is no name field; a server is shown as its address everywhere, which replaces names from earlier builds.
status: confirmed
tags: [settings, models, server, self-hosted, design]
canonical_for: [server-window, server-display-name]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22, looking at build 1710's server form (a tile named "qwen3:0.6b", a separate Models block with its own Add, then a separate key field with Remove and Save), the maintainer asked why it could not all be one window; then that the useless name field go, with the model name and the LLM/Transcription switch right in the window when a server is created, and the server's title come from its address. The REV 6 mockup renders were approved before wiring.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/ServerSheet.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Settings/APIAndModels/ServerSheetModel.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/AIRouting/ServerExplicitModelsTests.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-server-explicit-models.md, 2026-10-21-provider-key-tiles.md]
---

# A user's server is set up in one window and named by its address

## Context

The [explicit server models](2026-11-22-server-explicit-models.md) shipped
in build 1710 with the server's settings split across the inline key form:
a Server name and Base URL for a new server, a Models block with its own
field, type and Add button, then the key field with its own Remove and
Save. Two Saves for one server, and a name nobody needed: earlier builds
had named servers after a model ("qwen3:0.6b"), so the tile showed a model
where the server should be.

## Decision

- **One window.** The Custom server tile and each server's tile open a sheet
  (`ServerSheet`, state in `ServerSheetModel`) instead of the inline form.
  It has Base URL, API key (optional; "Saved · type to replace" when one is
  stored) and a Models list. A new server starts with one empty model row.
  One Save keeps the address, the key and the models together; Cancel
  changes nothing; Remove server is at the bottom left.
- **Model rows.** Each row has the model's name (typed, or chosen from ▾,
  the server's `/v1/models`), the type LLM or Transcription, the check's
  status (Checking…, Works, Failed with the server's reason under the row,
  Not checked) and ×. "+ Add model" adds a row. A name chosen from the list
  preselects its type; typing never changes the type.
- **Checks.** A row is checked 0.8 s after its name stops changing, at once
  when its type changes or a name is chosen from the list, and again when
  the address or key changes. A result applies only to the name, type,
  address and key it was sent for (see the explicit-models decision). Save
  checks every row whose result no longer describes it; a failure that Save
  finds stops it so the reason is seen, and the button becomes Save anyway,
  which keeps failed rows marked Not checked. The same name and type twice
  is refused on the second row.
- **Saving.** A new server, a changed address or a typed key goes through
  the ordinary key check first; a refusal saves nothing. Rows removed from
  the list un-set the features of their type that ran on them, with "<model>
  was removed from <server>" on those rows; a route on a model that was
  never listed stays.
- **One write, after the key check.** Save passes the address and key digest
  the rows were checked with; after the key check it computes them again and
  stores nothing if they differ (a key synced meanwhile, the server removed).
  Only then are the key and the server written: a new server enters the
  routing with its address, name and models in one write, so it is never
  listed before its key passed; an existing one gets its address, name and
  models in one write. Save ends there: what it reports is what is stored.
  The `/v1/models` list is loaded afterwards without Save waiting for it, so
  a server removed meanwhile cannot make a finished Save look failed or a
  failed one look finished.
- **The saved key stays with its address.** The saved key is used only while
  the address keeps the saved server's origin (scheme, host, port; a
  different path is the same server). For another origin nothing is sent:
  neither the row checks nor the key check on Save get the old key, the key
  field says "The saved key stays with the old address. Type it again to use
  it here.", and Save removes it unless a new one is typed. Save reads the
  key store when it writes, not when it began, so a key synced for the old
  address during the key check is removed too.
- **A typed key stays with the address it was sent to.** A typed key follows
  the address until a check first sends it; from then on, moving the address
  to another origin empties the field with "The key was typed for another
  address. Type it again to use it here."
- **Suggestions are the saved server's.** ▾ lists the saved server's
  `/v1/models` only while the address is the saved one; a new server or an
  edited address has no list, so a name from another server is never offered
  as this one's. The cached list carries a digest of the address it came from
  (not the address) and is shown only for that address; a refresh for a new
  address starts from an empty list, so a failed one does not keep the old
  models, and a refresh still in flight when Save changes the address does
  not write its list back.
- **Long lists scroll.** The address, key and rows scroll past 460 pt, and
  shrink further when the window has less room; the title and the footer
  with Save keep their height.
- **Name.** A server has no name field. Tiles, picker sections, the shared
  rows and messages show `ServerEndpoint.displayName`: host, the port unless
  it is the scheme's own, and the known local servers' names by port
  (`Ollama · localhost:11434`, `LM Studio · 127.0.0.1:1234`); any other
  address is itself (`vllm.company.ru`). Names stored by earlier builds are
  not shown; Save writes the address name into the stored `name`, so a
  rollback build shows it too.

## Why

A server is one thing to set up: where it is, how to get in, what it runs.
One window with one Save matches that, and every model's check result is
visible next to it before anything is stored. The address already says
which server it is; a typed name added a field and drifted from the truth.

## What we tested

- `ServerExplicitModelsTests`: a new server saved with its first model in
  one window (nothing stored before Save, tile named by the address);
  address required and empty rows ignored; a name chosen from the server
  preselects Transcription; a qwen-named model kept as Transcription when
  the user says so; one name as both types, a repeated type refused, removal
  of one type un-setting only its features; a failed check stops Save once,
  then Save anyway keeps it Not checked; an unreachable server; Cancel; a
  changed address and typed key saved with the models; a legacy name
  replaced; a pass under a replaced key not counting; an address typed
  during a check discarding the result; a refusal shown under the old key
  checked again before Save anyway; a server removed while the window is
  open; Remove server; display names for Ollama, LM Studio, plain hosts,
  default and custom ports, missing hosts.
- Offscreen renders of the window (new, two models of both types, a failed
  check, a new server's first check) and of the tiles, light and dark;
  the REV 6 mockups were approved before the code was wired.

- Review of PR #408 (queue ticket #414) found four gaps, closed together:
  the saved key went to an edited address; a new server was listed before
  its key check, and the key, address and models were written in separate
  steps around awaits; ▾ kept offering the old server's models after an
  address edit; a long model list grew the window past the screen. Tests:
  the builder's four probes plus a saved key not sent to and removed for
  another origin, the same origin with another path keeping it, a typed key
  used and saved, suggestions back with the saved address, a new server
  stored only after its key check, a refused key storing nothing, a server
  removed during the key check not brought back; a 16-row render.
- The second review (ticket #418) found the remaining gaps: a key typed for
  one address reused after a second address edit; a key synced for the old
  address during Save kept for the new one; Save reporting success after the
  server was removed during the list refresh it awaited; the old list kept
  after a failed refresh for the new address; and the 560 pt window growing
  to 604 pt. Tests: the builder's four new probes plus a typed key cleared
  after it was sent and another origin is typed (kept for another path), a
  key typed before the address following it until sent, Save returning once
  stored with the list loading afterwards, the catalog store not keeping a
  list for another address on a failed refresh nor writing back a list
  forgotten while in flight; renders assert the 600 × 560 window stays 560.

## Rejected

- Keep the inline form and add a Save per block: two Saves for one server
  was the complaint.
- A name field with a suggested name: the maintainer called the field
  useless; the address is the name.
- Keep the saved key for any address and only warn: a key is a credential
  for one server, and an address typed by mistake would receive it.
- Check only on Save: the user would not see which model fails until the
  end; rows check as they are typed, and Save checks only what is stale.

2026-11-22, branch `claude/server-one-window`.
