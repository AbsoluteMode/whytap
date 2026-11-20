---
id: readme-tool-accordion-2026-11-20
type: decision
title: README tool demos are an exclusive accordion of card images
summary: The README "Tools" section shows one card per tool as the summary of a details element sharing one name, so a click opens that tool's motion video and closes the previous one without leaving the page; the per-tool Markdown pages of the earlier grid were removed.
status: confirmed
tags: [readme, github, demos, documentation]
canonical_for: [readme-tool-demos]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user asked for a click that changes the picture and shows only the selected tool, rejected the per-tool page grid as unsatisfactory, chose to try the accordion, then asked for full-width cards that open to the video only, a short description inside the card, no duplicate subtitle, a gap before the video and the section name Tools.
    confirmed_at: 2026-11-20
  - type: repository
    reference: scripts/readme-tool-cards.py
    confirmed_at: 2026-11-20
  - type: repository
    reference: README.md
    confirmed_at: 2026-11-20
related: []
---

## Context

The README needed a gallery of the ten tool demos where a click selects one
tool and shows only its video. GitHub renders README HTML through a sanitizer:
no CSS, no JavaScript, SVG images receive no pointer events. The earlier grid
(2×5 image tiles) switched by linking every tile to its own copy of the page
under `docs/demos/`, so each click left the README and reloaded.

## Decision

Each tool is a `<details name="tool-demo">` whose `<summary>` holds a card
image. GitHub keeps the `name` attribute (prefixed `user-content-`), so the
browser keeps only one of them open. The card is an SVG generated in four
variants, wide and phone, dark and light, chosen by `<picture>` media queries;
the image sits in a `<picture>`, which stops GitHub from wrapping it in a link
to the raw file. The wide card holds the title, short steps and a two or
three line description; the phone card has the title and steps. Opening a
card shows only the motion video, 88% wide behind two em spaces so it sits
under the card, after an empty paragraph that gives 16 px of space.
`scripts/readme-tool-cards.py` generates the cards and the section.

## Why

It is the only GitHub-native control found that reacts to a click in place:
no page change, no reload, one open demo at a time.

## What was tested

- GitHub markdown API: `name` survives on `details`; a summary image is wrapped
  in a link unless it is inside `<picture>` or `<a name>`; an empty `<p>`
  survives.
- Live branch page in headless Chromium at 1280, 1012 and 375 px wide, dark
  and light: one details open after clicking two cards in a row, card and
  video geometry measured, no wrap of the disclosure marker on a 375 px phone
  once the card image is 92% wide and the phone variant is 300 units wide.

## Rejected

- Per-tool Markdown pages: change the URL and reload on every click.
- SVG tiles with interaction: GitHub shows SVG as an image without events.
- Two-column grid of details: details always take a full line; a table
  opens the video inside a narrow cell.
- Changing the card picture when open: GitHub has no state selector; the
  disclosure marker is the only open indicator.

2026-11-20, branch `claude/readme-demo-accordion`.
