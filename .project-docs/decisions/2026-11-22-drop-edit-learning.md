---
id: drop-edit-learning-2026-11-22
type: decision
title: Learn Vocab, Replace and Filler suggestions from the user's edits after Drop
summary: After a delivered take Whytap reads the same field once, five seconds later, through a fail-closed gate; a deterministic word diff turns repeated corrections (two takes in 14 days) into one suggestion. Replace is a new one-pass step before Filler, the Vocab list is trimmed per route instead of capped at 50 x 20, plaintext stays in memory, and a hidden 14-day calibration mode journals what the rules would do.
status: confirmed
tags: [drop, vocab, filler, replace, privacy, accessibility]
canonical_for: [drop-edit-learning, drop-replace, vocabulary-budget]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: ORCH-TASK 72. The user asked for liquid-glass drops right of the island that offer Vocab / Filler / Replace changes based on the user's own edits (asking for it to be "very beautiful and high quality"). Candidate rules were reviewed by three engines (inquisition 2026-11-22-160439-auto-vocab-candidates); the orchestrator forwarded the synthesis and the user's choices on Smart takes and calibration.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DropLearning/DropLearningCoordinator.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Filler/DropReplacements.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Settings/VocabularyBudget.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/DropLearning/DropLearningScenarioTests.swift
    confirmed_at: 2026-11-22
related: [2026-10-19-strict-drop-modes.md, 2026-11-20-input-language-suggestion.md, 2026-11-21-recorded-meeting-models.md, 2026-11-22-drop-learning-drops.md, 2026-11-22-drop-learning-default-on.md, 2026-11-22-drop-edit-observation.md, 2026-11-22-drop-learning-cut-tail.md]
---

## Context

Users fix the same recognition errors by hand: a name the provider writes in
Cyrillic, a filler Filler does not know yet, a filler it cuts that the user
types back. Whytap already has Vocab (terms sent to the provider) and Filler
(words cut before paste); it had no way to notice the corrections and no rule
that rewrites what the provider keeps getting wrong.

## Decision

- **One read of the same field** (superseded the same day: the field is now
  watched until it is sent, see [observation](2026-11-22-drop-edit-observation.md);
  the capture and every read keep the rules below). At the paste boundary, after focus is
  back on the target and right before Cmd+V, the paste engine hands over the
  element that has keyboard focus (the system-wide focused element of the
  frontmost app), from its identity and security metadata only. Five seconds
  later it is read once, only if that app is still frontmost, the same
  element still has keyboard focus and the gate still allows it. An app keeps
  its own focused element while another app is in front, so that alone never
  counts as focus. The transfer is bounded before it happens: the field must
  report its length (at most 20,000 UTF-16 units) and only that range is
  requested through AXStringForRange; a field that reports no length or
  cannot return a range is not read at all. A changed, closed or emptied
  field (Enter in a messenger), an AX error or a non-string value is skipped
  silently. Whytap's own editors are never read.
- **Own fail-closed gate** (`DropEditFieldGate`). `PasteTargetValidator` is not
  a password gate: it accepts any text field before its subrole and says yes
  on AX errors. The gate refuses AXSecureTextField, secure event input,
  terminals and password managers by bundle ID, Whytap's own process, unknown
  apps, non-text roles and any AX error other than a missing attribute (an
  IPC failure on the subrole fails closed). The gate sees metadata only and
  runs before any text is read, at capture, after the paste and at the read.
- **Compare with what was pasted**: the plain text of a rich paste (Slack,
  Telegram), after Smart, Replace and Filler. A semi-global word alignment finds
  the take inside the field; more than half its words changed = a rewrite,
  nothing learned. Case-only edits are not edits.
- **Rules, no model** (`DropLearningClassifier`):
  - A changed word that sounds like the heard one (transliterated edit distance
    or the same consonant skeleton: a Cyrillic "klod" and Claude) and is a term (digits, inner
    capital, mixed scripts, unknown to the system dictionary, or a capital the
    user added) -> Vocab, only if the wrong word is in the provider's raw text.
  - Grammar fixes (same stem, different ending, as between two case forms of a name) and rewrites are
    ignored.
  - Vocab does not reach On this Mac, batch recovery, Retry or the recorder
    fallback; there, when the route's list is full, when the term is already in
    Vocab and still fails, and for Smart-only errors -> Replace heard -> wanted.
    Replace is never offered when every heard word is a dictionary word.
  - A full list with no possible Replace -> "Vocab full" with the route's limit;
    Y opens Vocab.
  - The user undoes a fired replacement -> remove it; a Vocab term written where
    it was not said -> remove it from Vocab.
  - Deleting a spoken word or two -> Filler; typing back a cut filler, also at
    the edge of the take -> "Stop cutting".
  - Translated takes teach nothing.
- **Threshold**: the same correction in two takes within 14 days (one count per
  take). N is remembered forever; a suggestion left to expire starts counting
  over. One suggestion per take, never while the island is not idle (it waits
  for the next sighting).
- **Storage**: words stay in memory until Y. The ledger keeps HMAC-SHA256 of
  each candidate under a random per-install salt plus day numbers, in a local
  defaults key outside the backup and sync allowlist, never logged. A salted
  hash of a short word is a pseudonym, not encryption.
- **Replace is its own step** (`DropReplaceFilter`) in `DropOutputPolicy`, after
  Smart and before Filler, in both modes: one pass, no cascades, longest rule
  first, boundaries by letters/digits/underscore lookarounds (C++, .NET work;
  a name does not match inside a longer word that starts with it), code, links and e-mail addresses
  literal, a sentence-initial capital kept. Stored under
  `sidekey.drop.replacements.v1` (the Filler list keeps the legacy
  `sidekey.replace.terms`), included in the Vocabulary backup section and
  therefore in settings sync. The raw-partial salvage still pastes unprocessed.
- **Vocab is trimmed per route** (`VocabularyBudget`), not capped globally at
  50 x 20: the saved list holds up to 1,000 terms of up to 50 characters; each
  request takes, in list order, what its provider accepts: Deepgram about 450
  estimated tokens, ElevenLabs Scribe Live 50 terms of up to 20 characters,
  Soniox about 7,000 tokens of context, the OpenAI Realtime prompt about 800
  tokens, ElevenLabs recorded keyterms as before, and query terms within 8 KB
  of percent-encoded URL. Tokens are estimated as UTF-8 bytes / 3.
- **Y goes through the same stores** the editors use. The Vocab editor loads
  its list once and saves it whole, so `VocabularyCache` and `FillerTermsStore`
  post a change notification and the open editors reload.
- **Switch** (`sidekey.dropLearning.enabled`; Settings, Other, Drop, "Learn
  from my edits"): on unless the user switched it off, see
  [default on](2026-11-22-drop-learning-default-on.md). The drops that ask are described in
  [the drops decision](2026-11-22-drop-learning-drops.md).
- **Calibration** (`sidekey.dropLearning.calibration`, hidden; since the
  [observation](2026-11-22-drop-edit-observation.md) it journals one
  `observed` entry per watched field instead): reads at 5 s and
  then every second until the field holds still for three reads or 30 s,
  journals each read (words of the edits, candidates, which ones the 5 s read
  missed) to Application Support/<bundle id>/drop-learning/calibration.jsonl,
  counts in its own ledger and is a dry run: Y saves nothing (since the
  [developer journal](2026-11-22-drop-learning-cut-tail.md), only while
  learning is off; with learning on it journals beside real learning). The journal is
  written only into a real 0700 directory of this user, through a regular
  file with one name (a hard link is refused) opened without following links
  and made 0600 before each write. It
  ends itself 14 days after it was first seen; expiry and switching it off are
  checked at launch, every hour and before every read and journal write, so a
  read already scheduled stops and the journal and its ledger are deleted
  without another Drop. Switching learning off likewise stops a scheduled read.
  Release reads once at 5 s.
- **Fired fillers** are collected on the same masked text the Filler step
  sees, so a filler word inside protected Markdown code is not counted as cut.

## Why

Repeated manual fixes are the clearest signal a user can give and they need no
extra UI. A second sighting filters typos and one-off rewrites. Reading once at
5 s keeps the field read short and predictable; calibration measures what the
longer read would add before deciding. Vocab only helps the provider, so a
correction the provider never saw (Smart, batch, On this Mac) belongs to
Replace, and Replace must never touch ordinary words.

## What we tested

Scenario tests (fake field and dictionary): repeated correction to Vocab on the
second take; 14-day window; one count per take; filler deletion; filler typed
back (inside and at the edge); words Smart added are not fillers; N forever;
expiry restarts counting; full ElevenLabs list -> Replace or Vocab full with
50/50 and Y opening Vocab; On this Mac -> Replace; term already in Vocab ->
Replace; Vocab term removal; undoing a replacement; Smart-only error ->
Replace; translation ignored; grammar fixes and rewrites ignored; secure,
terminal, password manager, own, AX-error and value-less fields refused; field
gone or emptied counts nothing; a new take cancels the read; disabled feature
captures nothing; never over a busy island; ledger has no words and is not in
backups; calibration settles, journals 0600, dry run, ends after 14 days.
Replace: no cascades, boundaries, protected code/links/e-mail, casing, Replace
before Filler. Budget: per-route limits, Cyrillic, URL size, dedupe.

## Rejected

- An LLM judging the edits: content would leave the Mac and results would not
  be reproducible.
- Reading until the field is stable in release: longer polling of a field the
  user types in; measured first in calibration.
- Bare Y/N keys: the user is typing at that moment; answers are clicks and
  Control-Y / Control-N while the drops are shown.
- LocalNotificationHub for the drops: it writes history before showing.
- Storing candidates in plain text or in the History database: the words are a
  speech profile.
- One global 50 x 20 Vocab cap: it wasted every provider with a larger limit.
- Writing Replace rules into the Filler key: it is the Filler list.

Builder review of PR #406 (queue #409) found the gate reading the value
before its checks, capture after the paste delay, calibration continuing after
opt-out, a journal accepting a 0644 file and fillers in protected code counted
as cut; all five were fixed with regression tests before integration. The
second review (queue #412) found a full value read when the field reports
no length, the app's own focused element counted as focus after the user
switched apps, and the journal writing through a hard link; the read now
needs a length and requests only that range, focus is the system-wide
focused element of the frontmost app captured inside the paste engine
right before Cmd+V, and the journal refuses a file with more than one name.
The third review (queue #415) found that focus could move during the
blocking length query or during the capture itself; the read now confirms
keyboard focus and the gate again after the length query and after the
range transfer, and the paste engine posts no Cmd+V (and restores the
clipboard) when another app took focus while the field was captured. The
fourth review (queue #417) found focus could still move during the gate's
own metadata calls after the length query, and that the capture callback
ran with learning off; focus is now checked before and after the gate, so
keyboard focus is the last thing confirmed before the range request, and
the callback is passed only while learning or calibration is on.

2026-11-22 · ORCH-TASK 72 · PR #406: candidate logic (drops UI follows)
