---
name: standard-documentation
description: "The single rubric for excellent technical documentation that tech-writer builds to whenever docs are created, updated, or refactored (README, reference, guides, runbooks, architecture, changelog): Diátaxis mode selection, the one-mode/one-reader/one-task gate, anti-bloat minimalism, writing style, scannability, LLM-consumability, and redaction discipline. Defines WHAT good docs look like; it does NOT define the tech-writer's working conduct or report envelope (owned by the tech-writer agent body)."
---

# Standard: Technical Documentation

The **one** definition of excellent technical documentation. The `tech-writer` builds to it. Excellence is **not comprehensiveness** — it is the *smallest* document that gets *one* reader to *one* goal, in *one* mode. Bloat is the default failure; every rule here exists to prevent it.

This skill defines **WHAT good looks like**. It does NOT define the tech-writer's working conduct (read the source, verify accuracy, never hallucinate) or its report envelope — those live in the agent body.

## Philosophy

A reader is never "reading the docs" in general — they are in **one** state: learning, doing a task, looking something up, or trying to understand. A document serves exactly one of those. Trying to serve more than one is the primary cause of documentation that is large, unusable, and wrong. *Less, correctly targeted, beats more.*

This applies whether the reader is human or an agent retrieving a chunk — see LLM-readability below, including the one place the two audiences genuinely diverge: an `agent`-or-`both` audience can justify more self-contained structure than a `human`-only reader needs. For a `human`-only reader, neither state justifies more content than minimalism already allows.

## The pre-write gate (declare before writing a word)

Before writing or restructuring any document, state three things. If you cannot, the doc is not yet scoped — and will bloat.

1. **One mode** — which Diátaxis mode is this (below)?
2. **One reader** — who exactly, and are they *acquiring* skill (a novice/learner) or *applying* skill they already have (a competent practitioner)?
3. **One task/goal** — stateable in a single sentence.

These three **are the length budget.** Once fixed, most candidate content self-evidently falls out of scope (rationale leaves a how-to; alternatives leave a tutorial; examples leave a reference).

## The doc-type framework (Diátaxis) — pick ONE mode

Two axes select the mode. Answer both; the mode is determined:

| The content informs… | …serving the reader's… | → Mode |
|---|---|---|
| **action** (doing) | **acquisition** (studying) | **Tutorial** |
| **action** (doing) | **application** (working) | **How-to guide** |
| **cognition** (understanding) | **application** (working) | **Reference** |
| **cognition** (understanding) | **acquisition** (studying) | **Explanation** |

| Mode | Purpose | MUST contain | MUST NOT contain | Voice |
|------|---------|--------------|------------------|-------|
| **Tutorial** | Teach a beginner basic competence via a lesson | One linear, guaranteed-to-succeed path; concrete steps with visible results | Alternatives/branches; *why* explanations; anything that can fail | Teacher-led ("we"); reader is a learner |
| **How-to guide** | Help a competent user complete one real task | Ordered steps to a real-world goal; branches for real conditions; a task-named title | Teaching of foundations; exhaustive background; internals | User in charge; assumes competence |
| **Reference** | State facts for lookup while working | Structured lists/tables of facts (params, flags, options); consistent shape mirroring the code | Illustrative examples; *why*; task walk-throughs | Austere, factual, neutral — describe the machinery |
| **Explanation** | Give understanding — the *why*, context, trade-offs | Concepts, reasons, alternatives, connections | Step-by-step instructions; dense reference tables | Discursive, reflective |

**One document = one mode.** When editing, the sharpest diagnostic is: *"which single mode is this, and what content is bleeding in from the other three?"* Split the bleed out into its own doc and **link** to it.

## Minimalism & anti-bloat (the core discipline)

1. **Smallest doc that serves the reader.** Ship the shortest thing that reaches the goal. Prune every excess word.
2. **Progressive disclosure — link, don't inline.** Keep the primary path short; push depth, background, and edge cases to linked pages. Keep the basic case to a few lines with a link to more.
3. **Reference, don't duplicate.** Never hand-restate signatures, parameter lists, or config schemas — they go stale and inflate the doc. Prefer generated reference and link to it; write prose only for what a human must explain.
4. **No speculative coverage.** Document what this reader needs for this task now — not every option "just in case." Comprehensiveness-for-its-own-sake is an anti-goal.
5. **Say it once.** Cut redundancy across docs — each fact lives in one canonical place, in its correct mode; everywhere else links.
6. **A volatile fact lives in exactly one place within a document, too.** This is distinct from rule 5 above (which is scoped to redundancy ACROSS documents) and from the redaction/generated-reference rule against hand-restating something machine-generated — this is about a single document mentioning the same changeable fact (a URL, a hostname, an endpoint, a version number, a port — anything expected to change) more than once within its own body. Every mention past the first is a second place that fact can go stale independently of the first. State it once, then refer back ("the endpoint above") or link internally — never repeat the literal value.
7. **Don't document the obvious.** No prose restating what the UI label, signature, or code already says.
8. **Front-load and stop.** Lead with the most important thing; end the document when the reader's need is met. Don't pad to look thorough.

**LLM-readability's relationship to this discipline is audience-conditional — see LLM-readability below for the full rule.** For a `human`-only audience, it is not an exception: it is satisfied *inside* this discipline, exactly as before — a self-contained section is not more content, it is the same content with its cross-references resolved, and "agents might retrieve this chunk out of context" is still not a reason to inline depth minimalism says should be linked. For an `agent`-or-`both` audience, LLM-readability becomes a **primary driver** of the doc's structure rather than a constraint capped by human-only minimalism — a genuine relaxation, not this rule restated more strongly.

## Writing style

- **Active voice** — make clear who performs the action. Start statements with a verb.
- **Second person** ("you"), **present tense**. (Tutorials may use the teacher's "we".)
- **Concision** — bigger ideas, fewer words; short sentences, short paragraphs; reads well aloud.
- **Conditions before instructions** — "To view the report, click View," not the reverse.
- **Plain language** — minimal jargon; contractions fine; no gratuitous "please"; no weak openers (*there is/are*, *you can just*).
- **Consistent terminology** — one term per concept throughout; no synonyms-for-variety (also aids translation).

## Scannability

Readers are in a hurry and skim — structure for jumping, not linear reading.

- **Descriptive, sentence-case headings**, no trailing punctuation, that let a reader find their part.
- **Numbered lists** for sequences/steps; **bulleted lists** for non-sequential collections; **tables** for structured data with multiple properties.
- Keep list items **parallel** in structure and short; introduce a list with a full sentence; never a one-item list.

## LLM-readability

Documentation is read by agents as often as by humans now — a retrieval system hands a model one chunk (often one section) with no guarantee the surrounding document came with it. A section that only makes sense next to its neighbors is broken for that consumer, not just less convenient.

**This section's force depends on the resolved audience** (`agent` / `human` / `both` — `flow-documentation`'s Step D1 resolves and hands you this before you write a word):

- **Audience = `human`.** The rules below still apply, as scannability/self-containment hygiene — but they stay bounded by the same minimalism budget as everywhere else in this skill. Do not inline depth (a full definition, a repeated background section) that a link would carry, just because "a chunk might get retrieved out of context" — this reader reads the whole document, not a retrieved chunk.
- **Audience = `agent` or `both`.** LLM-readability is a **primary driver of the document's structure here, not a secondary constraint capped by human-only minimalism.** The doc MAY justify additional self-containment a human-only reader wouldn't need — for example, restating a term's definition inline in a section rather than only linking to it, when that's what makes a retrieved chunk stand alone on its own. This is a genuine relaxation of "never inline for retrieval," not the same rule restated more strongly, and it can produce a **materially different document structure** than the human-only case: more, smaller, fully self-contained sections rather than one flowing narrative that leans on its neighbors.

Regardless of audience, the mechanics are the same:

- **Every section is self-contained.** Restate the subject in the section's own heading or opening sentence — don't rely on a reader having seen an earlier heading. Never open with a dangling **"it" / "this" / "the above" / "as mentioned"** that only resolves by reading a prior section.
- **Expand every acronym once per section**, even one already expanded earlier in the document — a chunked retrieval may hand a model this section alone.
- **Structured facts go in tables, not prose.** Any catalogue, parameter list, flag set, or set of attributes — a table (already required by Scannability above) is also what makes the fact machine-parseable, not just human-scannable. Never bury a lookup fact inside a sentence.

This does not relax the one-mode / one-reader / one-task gate — even an `agent`-or-`both` document still serves one reader-state; the audience only changes how much a `human`-only budget would otherwise have said to link out instead of inline.

## Code fences

- **Every code fence carries a language tag, with a one-sentence caption immediately before it** stating what the block shows. No bare fences (\`\`\` with no tag) — an untagged fence can't be syntax-highlighted or reliably parsed by a downstream agent.
- Use `text` for console output, URLs, or other plain non-code values. Use `ini` or `bash` for `KEY=value` configuration blocks — pick whichever matches how the block is actually consumed (a `.env` file vs. a shell export).

## Redaction discipline

**No person names, ticket/issue numbers, or internal filesystem paths in any document this skill governs.** These are internal identifiers a published doc must never carry — a person's name attributes text to someone who didn't sign up to be documentation, a ticket number (e.g. `PROJ-1234`) exposes a tracker most readers can't reach, and an internal path (e.g. `/Users/name/...`, `C:\Users\...`) leaks local machine/environment detail that means nothing to the reader and may leak a username.

**A prompt instruction alone is not sufficient enforcement of this rule.** Source material used as writing input — a handoff brief, ticket text, chat logs — commonly carries all three (names, ticket numbers, and local paths), which is exactly the kind of source an agent naturally quotes or paraphrases from while drafting. An instruction that says "don't include these" competes, at generation time, against source material that already contains them; nothing about a prompt-level rule reliably wins that competition.

**What this means for enforcement, stated explicitly rather than left implicit:**
- The tech-writer's own conduct includes a **required self-scan pass** over its own draft before handing back (see the agent body), split into two halves of very different reliability: an actual **`Grep` pattern scan** for ticket-ID-shaped identifiers (e.g. `[A-Z]{2,}-\d+`) and absolute local paths (e.g. `/Users/...`, `/home/...`, `C:\Users\...`) — a real, tool-driven scan for those two categories, though the ticket-ID half is deterministic in *finding matches*, not in *judging* them: the same shape matches ordinary technical vocabulary (`UTF-8`, `SHA-256`, `RFC-2119`, `ISO-8601`, and similar), so the tech-writer applies judgment to each match rather than removing everything the pattern touches — mirroring, by judgment, the allowlist `doc-lint.sh` (below) applies mechanically — plus a **best-effort, LLM-driven judgment pass** for person names, which `Grep` structurally cannot pattern-match (no regular shape distinguishes a name from an ordinary technical term). The `Grep` half closes the pattern-*matching* part of this gap, filtered by judgment; the name half remains exactly as unreliable as a prompt-only instruction, for the identical reason.
- **A genuinely independent, orchestrator-run mechanical gate — one the tech-writer itself cannot skip or misjudge — exists.** `flow-documentation` (Step D5) runs `procedure-doc-lint`'s `doc-lint.sh` against every tech-writer draft, from OUTSIDE the agent that authored it, before any fact-check or PR step — the same script-over-prompt discipline this framework already applies to git commits and tracker writes. It re-checks the two pattern-matchable redaction categories (ticket-IDs, local paths) independently of the tech-writer's own `Grep` pass, and additionally enforces structure/format (bare code fences, single-item lists) that no other script covers. **It is NOT a substitute for the tech-writer's own self-scan** — the two are complementary layers, not one replacing the other — and it does **not** extend to person names — for the same reason stated above, so that half of redaction discipline remains an LLM judgment pass with no mechanical backstop. Do not report a document as redaction-clean without having actually performed both self-scan passes, and do not claim `doc-lint.sh`'s determinism extends to person names either.

## Leave out (the anti-pattern catalogue)

Mixing modes · wall of text (no headings/lists) · documenting the obvious · duplicating the code or generated reference · comprehensiveness for its own sake · pre-announced/future features · stale-prone implementation detail embedded in prose · inlining what should be linked · passive voice / hedging / weak openers · inconsistent terminology · wrong-audience calibration (teaching experts, or assuming competence in novices) · a section that only reads correctly next to its neighbors · a bare/untagged code fence · a person name, ticket number, or internal file path in the output · a volatile fact (URL, hostname, endpoint, version, port) restated at more than one place within the same document · a genuinely necessary step or fact cut in the name of minimalism.

## Excellence checklist (self-check before handing back)

- [ ] Exactly **one** Diátaxis mode; nothing bleeding in from the other three.
- [ ] The **one reader** and **one task** are identifiable; assumed prior knowledge matches the reader.
- [ ] It is the **smallest** doc that reaches the goal; depth is **linked**, not inlined.
- [ ] **Nothing essential to the reader's one stated task was cut in the minimalism pass.** Re-read the
  draft against the one-task goal from Step 3 of the pre-write gate and confirm no genuinely necessary
  step, fact, or precondition is missing — not just that nothing extra was added. This is the deliberate
  counterweight to every other item on this list: they all guard against *too much*; this one guards
  against *too little*, because cutting essential content is exactly the failure mode a minimalism-only
  self-check cannot catch on its own.
- [ ] No duplication of code/generated reference/other docs; no speculative or obvious content.
- [ ] Most important info front-loaded; ends when the need is met.
- [ ] Active voice, second person, present tense; conditions before instructions; consistent terms.
- [ ] Scannable: descriptive sentence-case headings; correct list/table choice; parallel, short items.
- [ ] No pre-announced features; volatile facts referenced/generated, not restated; a volatile fact stated
  once per document, never scattered across multiple mentions within it.
- [ ] Every section is self-contained: subject restated, acronyms expanded, no dangling backward reference.
- [ ] Every code fence has a language tag and a one-sentence caption.
- [ ] Redaction self-scan performed: no person names, ticket numbers, or internal file paths in the output.

## Constraints (NEVER violate)

- Never write a document that serves more than one Diátaxis mode — split and link instead.
- Never pad for the appearance of thoroughness, restate the code, or inline what a link would carry.
- Never document assumptions — verify against the source; if uncertain, say so rather than invent.
- Never begin without the one-mode + one-reader + one-task gate satisfied.
- Never ship a bare/untagged code fence.
- Never ship a person name, ticket number, or internal filesystem path in the document — and never report the redaction self-scan as done without having actually performed it.
