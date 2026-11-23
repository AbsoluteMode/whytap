---
id: drop-learning-cut-tail-2026-11-22
type: decision
title: Learning from edits ignores a cut tail, hears voiced and voiceless pairs as one sound, counts its reasons and keeps a developer journal
summary: Words cut from either edge of a take no longer make it a rewrite or join the neighbouring fix; the consonant skeleton treats voiced and voiceless pairs and "dzh" as one sound; one changed part of a hyphenated word is the term; DropLearningStats counts why each take did or did not teach anything, with reason names only; and calibration with learning on is a developer journal beside real learning, with the edited words, the app and every refusal reason.
status: confirmed
tags: [drop, learning, privacy]
canonical_for: [drop-learning-cut-tail, drop-learning-stats]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: ORCH-TASK 72. Live check on build 1722 failed. In the Claude desktop chat the user twice fixed a misheard word to "jev" by hand and sent with Return; no drops appeared ("the drops did not appear"). The orchestrator asked for the cause and a way to see the reason for a refusal without revealing text.
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: ORCH-TASK 72 REV 19 item 19. The user wants a development log on their own Mac ("we need to collect some logs here for development"): one entry per Drop with time, app, whether the field was read, how the watch ended, whether a diff was found, the reason each gate refused, and whether a drop was shown; local only, deleted after 14 days; the edited words are needed for debugging on the user's Mac, while ordinary users keep only hashes.
    confirmed_at: 2026-11-22
  - type: trace
    reference: Build 1722 read only. The ledger key existed with an empty "seen" map, so both fields were read and classified with no candidate. History showed the provider wrote the Cyrillic "Dzheff" (once inside a hyphenated word, "Dzheff-modeli") and added a made-up tail of 4 and 16 words after each phrase; the user cut the tails and fixed the word.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DropLearning/DropEditDiff.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DropLearning/DropLearningCandidates.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/DropLearning/DropLearningStats.swift
    confirmed_at: 2026-11-22
related: [2026-11-22-drop-edit-learning.md, 2026-11-22-drop-edit-observation.md]
---

## Context

The first live check of learning from edits after watching was added
(build 1722) gave no drops. The field reads worked: the ledger was written
with no candidates. Three rules each dropped the correction.

1. The provider added a made-up tail (4 and 16 words). The user cut it.
   The diff counted the cut words as changes, so the first take was over
   the 50 % rewrite share and taught nothing.
2. In the second take the cut tail sat right after the fixed word, so the
   diff made one hunk of five removed words and one typed word. Hunks over
   three words are ignored.
3. Cyrillic "Dzheff" and "jev" did not sound alike: the transliteration is "dzeff",
   whose consonant skeleton ("dzf") differs from "jev" ("djv") in two of
   three letters.

Nothing showed which rule refused, because learning logs nothing.

## Decision

- **A cut is not a rewrite.** Words removed at the start or the end of
  the take with nothing typed in their place are a cut. They become their
  own hunk, next to any fix, and the rewrite share is counted over the
  kept words only. At least one word must still match and the kept part
  must be at most half changed, so cutting most of a take and typing
  something else is still a rewrite.
- **Sound-alike.** The consonant skeleton treats "dzh" and "dz" as "j",
  and voiced and voiceless pairs (b/p, d/t, g/k, v/f, z/s) as one sound.
  Russian spelling of a heard name often swaps them.
- **Hyphenated words.** When only one part of a hyphenated word changed
  (Cyrillic "dzheff-modeli" to "jev-modeli"), that part is the term; the raw check
  accepts it as part of a raw word.
- **Reason counters.** DropLearningStats keeps counts per fixed reason
  name in `sidekey.dropLearning.stats.v1`: how the watch ended, why an
  edit was refused (`take.rewrite`, `edit.tooLong`, `cut.long`,
  `sub.notSoundAlike`, `sub.notInRaw`, `sub.notTerm`, `sub.noVocabRoute`
  and others), which candidates were counted and whether a suggestion was
  shown. No words, hashes or app names. Local defaults, outside backup
  and sync, deleted when learning and calibration are both off.
- **Developer journal.** The hidden calibration switch
  (`sidekey.dropLearning.calibration`, set with `defaults write`, no
  Settings control) keeps its journal at Application
  Support/<bundle id>/drop-learning/calibration.jsonl (0600, outside
  backups, sync and logs) and ends itself after 14 days, deleting it.
  With learning on it now runs beside real learning: suggestions are
  real and Y saves. Only with learning off is it the dry run it was.
  Each Drop gets one entry: time, app bundle ID, mode, Vocab route, the
  capture refusal (`notFrontmost`, `noFocusedElement`, `secureField`,
  `secureInput`, `deniedApp`, `notTextRole`, `axError` and others) or how
  the watch ended, reads, every refusal reason from the counters, the
  candidates with their counts against the threshold, the edited words
  (removed and typed per hunk) and whether a drop was shown. The words are
  kept on purpose: a refusal such as "Dzheff" to "jev" cannot be judged
  without them. Ordinary users never have the switch on; for them the
  disk holds only the ledger hashes and the reason counters.

- **Paste boundaries** (builder review, queue #449). The paste counts
  only once it is seen verbatim in the field. That first sighting records
  the field words before and after it, and every later read compares only
  the region between them, with a global alignment. A read whose
  surroundings changed is not compared (fail closed). So a draft around
  the paste, or a draft left after the whole paste was deleted, never
  becomes a correction, and a fix next to a cut head or before a cut tail
  inside a draft is still found. Changed words sit next to the kept text;
  cut pasted words and typed field words are outermost and are separate
  hunks.
- **Identical copies** (builder review, queue #454). When the paste
  appears verbatim more than once (a new paste next to an identical older
  draft), the caret decides: each read also asks the field for its
  selection (`AXSelectedTextRange`, a position, never text), and right
  after Cmd+V it sits at the end of the new copy. The copy that ends at
  the caret is watched. Only a collapsed selection counts, and only at
  the exact end of the delivered text itself (with its own punctuation
  and spaces, or trimmed when the app dropped outer whitespace), whose
  words must be exactly one copy's; a caret past an older copy's
  punctuation or the space after it, inside a word, or selected text
  proves nothing (builder review, queue #464). Without such a
  caret the take ends as `ambiguous`: nothing is learned and no words are
  journaled. A single copy needs no caret, but if a further verbatim copy
  appears after the paste was placed (a late paste next to an identical
  draft that was seen first), the take ends as `ambiguous` too (builder
  review, queue #459).
- **Typed words at the edge.** With a known paste place, the typed word
  nearest the paste inside the watched region is still the word before or
  after the take, even when the whole typed run is longer than one edit,
  so a cut filler typed back next to the paste with other words stops
  cutting. Words outside the region (an older draft) never count.
- **Undo on whole words.** Undoing a whole fired Replace rule or a whole
  Vocab term, hyphenated or not, is checked before the hyphen part is
  taken, so it offers the removal of that rule or term.
- **Real outcomes in counters and journal.** `suggested` is counted only
  when the drops really showed; when they could not (an agent answer
  holds the island) it is `suggestion.notShown`. `readable` (the field
  was read) and `aligned` (the paste was found in it) are separate. A
  failed accessibility query for the focused element at capture is
  `axError`, not "no focused element". A capture refusal belongs to the
  take that asked for it; the next take clears it. Refused deletions and
  insertions have reasons (`del.*`, `ins.notACutFiller`). A delivery that
  pasted no learnable text (Whytap's own editor, a failed paste, no
  learning data, and the raw partial pasted when Fast mode recovery
  salvages a failed take: `rawSalvage`, `rawSalvageFailed`) is counted
  and journaled as `delivery.<reason>`, with the target app and the mode;
  one entry per salvage, and a later Retry is its own delivery; a take
  cancelled or failed before any text is not a delivery and is not
  journaled.
- **Switching calibration off mid-watch.** A watch that saw calibration
  off at any read never writes a journal entry, even if calibration is
  switched on again before the watch ends.

## Why

- A made-up tail is a known provider failure, and cutting it is the most
  common edit next to fixing a word. Treating it as a rewrite threw away
  exactly the takes that most need a Vocab term.
- The skeleton rule exists for names heard in another language; voicing
  is the usual difference there.
- The counters answer "why no drops" from `defaults read` without
  turning on calibration, which journals the words.

## What we tested

- A scenario test with the structure of both 1722 takes (made-up tails,
  the fix inside a hyphenated word and before a cut tail): the second
  take gives the Vocab suggestion for "jev", and the counters show two
  cleared watches, two Vocab candidates, two long cuts and one shown
  suggestion. It failed before the change.
- Diff tests: a long cut tail aligns; a cut tail next to a fixed word is
  its own hunk; a cut head aligns; a cut plus a rewrite of the rest, or a
  different message, is still a rewrite.
- Cyrillic "Dzheff" and "jev", "klodu" and "Claude" sound alike;
  "otchyot" and "prezentatsiyu", "Seve" and "Mishe" do not (all Cyrillic
  in the tests).
- The counters hold no words, are not in the backup registry, and are
  deleted when learning is switched off.
- With learning and calibration on, the same two takes give a real
  suggestion and three journal entries (app, end reason, refusal reasons
  including the long cuts, counts against the threshold, the words, the
  drop shown, and a skipped take with its capture refusal). Without
  calibration nothing is journaled. A refused capture names its reason.
- Builder probes from queue #449 as scenario tests: a fix next to a cut
  head; a fix before a cut tail inside a draft; deleting the whole paste
  while a draft survives teaches and journals nothing from the draft;
  undoing a whole hyphenated Replace rule and Vocab term offers its
  removal; counters say `suggestion.notShown` when an agent answer hides
  the drops; refused deletions and insertions have reasons; a readable
  field without the paste is readable but not aligned; an abandoned
  capture refusal never explains a later delivery; an edit seen while
  calibration was off is never journaled; a failed focus query at capture
  is `axError`.
- Builder probes from queue #454: a fix to a new paste before or after an
  identical draft counts when the caret marks the new copy; a fix to the
  older draft is not learned; two copies without a usable caret teach and
  journal nothing (`end.ambiguous`); a filler typed back next to the paste
  with other words, before or after it, stops cutting; a skipped delivery
  is journaled with its app and mode; a read carries the caret and drops
  an impossible one. From queue #459: a caret inside the older copy's
  last word places nothing; a late paste after the identical draft was
  seen alone teaches and journals nothing; a selection is not a caret.
  From queue #464: a caret just past the older copy's "!" or the space
  after it places nothing, while the caret at the new copy's end still
  places it. The raw salvage call itself is in AppDelegate and is
  covered by review, not by a test.
- Not verified here: the built app. The acceptance is the same dictation
  in Claude desktop.

## Rejected

- Prefer the last copy when the paste appears twice: the older draft may
  be after it, and its edits would be learned and journaled.
- Accept a caret anywhere between the copy's last word and the next
  word: punctuation the user typed after an older copy would then point
  at it.
- Re-place the paste on the caret when a second copy appears later: a
  copy the user typed again would then be taken for the paste.
- Read the field before the paste to find the new copy: one more read of
  the user's text, while the caret is only a position.
- Raise the hunk limit above three words: it would let real rewrites
  through as substitutions.
- Log the refusal reason to the system log: learning keeps nothing in
  logs, and the counters are enough.
- Store the refused words for every user: calibration exists for that,
  and only the developer turns it on.
- A Settings switch for the journal: it would offer every user a log of
  their own words for a developer need.
- Keep calibration a dry run even with learning on: the developer could
  not use real learning and the journal at the same time.

2026-11-22, branch claude/drop-learning-cut-tail.
