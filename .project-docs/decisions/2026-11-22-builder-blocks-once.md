---
id: whytap-builder-blocks-once-2026-11-22
type: decision
title: The queue builder blocks a PR once with every finding
summary: Before blocking, the builder finishes the whole inspection and lists all problems at once; a later attempt of the same PR is blocked again only for a problem the fix introduced or a listed item still unfixed.
status: confirmed
tags: [agents, queue, builder, review, integration]
canonical_for: [builder-block-policy]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer asked the builder to validate all findings and report them at once, to re-block only when the error is produced by the fix, and to remember that rule.
    confirmed_at: 2026-11-22
  - type: repository
    reference: scripts/build-queue-builder-prompt.md
    confirmed_at: 2026-11-22
related: [2026-11-19-on-demand-build-queue-builder.md, ../processes/shared-app-development.md, 2026-11-23-builder-queue-watchdog.md, 2026-11-23-builder-queue-flaky-tests.md]
---

# The builder blocks a PR once with every finding

> Partly superseded on 2026-11-28: the builder no longer reviews code or blocks on review findings; "block once" now applies to failing checks only. See [builder never reviews](2026-11-28-builder-never-reviews.md).

## Context

The builder blocked PR #374 (one MCP server for the Whytap plugin) seven times
in a row. Each time it found one or two new edge cases that had been in the
code from the start and could have been found on the first attempt. Every
round cost the feature session about an hour and the builder a full
re-inspection.

## Decision

Before setting `blocked`, the builder finishes the whole inspection (every
probe and check across all paths the PR touches) and writes all problems into
the ticket note as one numbered list. A probe that exposes a class of error is
reported as that class, with every instance checked. A later attempt of the
same PR may be blocked again only for a problem the fix itself introduced or a
listed item that is still not fixed. A problem that was already present but
missing from the previous list never blocks: the builder fixes it when the fix
is mechanical and safe, otherwise records it as a follow-up and continues.

## Why

A block is a round trip through another session and a rebuild. Findings
delivered one at a time turn one review into many; the author cannot fix what
it was not told. Holding the builder to its own previous list makes the first
inspection complete and keeps the cost of a missed finding with the builder.

## Not chosen

- Unlimited re-blocks for anything new: this produced the seven rounds.
- A fixed attempt limit: it would let a real regression from the fix through.
- Moving the rule into the queue helper: the helper cannot tell which problems
  existed before; this is a review judgment for the builder.

2026-11-22
