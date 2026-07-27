---
name: standard-documentation
description: The single definition of excellent technical DOCUMENTATION — the shared rubric the docs-writer BUILDS to. Applies whenever documentation is created, updated, or refactored (README, API/reference, guides, tutorials, runbooks, architecture, changelog). Defines the Diátaxis mode framework (tutorial / how-to / reference / explanation + the compass that selects one), the pre-write gate (one mode + one reader + one task) and the anti-bloat / minimalism rules that keep a document SMALL (smallest-doc-that-serves-the-reader, progressive disclosure / link-don't-inline, reference-don't-duplicate, no speculative coverage, don't document the obvious, front-load-and-stop), writing style (active voice, second person, present tense, concision, conditions-before-instructions, consistent terminology), scannability (headings / lists / tables), and the anti-patterns to leave out. This is WHAT excellent docs look like; it does NOT define the docs-writer's working conduct or report envelope (that lives in the docs-writer agent body).
---

# Standard: Technical Documentation

The **one** definition of excellent technical documentation. The `docs-writer` builds to it. Excellence is **not comprehensiveness** — it is the *smallest* document that gets *one* reader to *one* goal, in *one* mode. Bloat is the default failure; every rule here exists to prevent it.

This skill defines **WHAT good looks like**. It does NOT define the docs-writer's working conduct (read the source, verify accuracy, never hallucinate) or its report envelope — those live in the agent body.

## Philosophy

A reader is never "reading the docs" in general — they are in **one** state: learning, doing a task, looking something up, or trying to understand. A document serves exactly one of those. Trying to serve more than one is the primary cause of documentation that is large, unusable, and wrong. *Less, correctly targeted, beats more.*

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
6. **Don't document the obvious.** No prose restating what the UI label, signature, or code already says.
7. **Front-load and stop.** Lead with the most important thing; end the document when the reader's need is met. Don't pad to look thorough.

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

## Leave out (the anti-pattern catalogue)

Mixing modes · wall of text (no headings/lists) · documenting the obvious · duplicating the code or generated reference · comprehensiveness for its own sake · pre-announced/future features · stale-prone implementation detail embedded in prose · inlining what should be linked · passive voice / hedging / weak openers · inconsistent terminology · wrong-audience calibration (teaching experts, or assuming competence in novices).

## Excellence checklist (self-check before handing back)

- [ ] Exactly **one** Diátaxis mode; nothing bleeding in from the other three.
- [ ] The **one reader** and **one task** are identifiable; assumed prior knowledge matches the reader.
- [ ] It is the **smallest** doc that reaches the goal; depth is **linked**, not inlined.
- [ ] No duplication of code/generated reference/other docs; no speculative or obvious content.
- [ ] Most important info front-loaded; ends when the need is met.
- [ ] Active voice, second person, present tense; conditions before instructions; consistent terms.
- [ ] Scannable: descriptive sentence-case headings; correct list/table choice; parallel, short items.
- [ ] No pre-announced features; volatile facts referenced/generated, not restated.

## Constraints (NEVER violate)

- Never write a document that serves more than one Diátaxis mode — split and link instead.
- Never pad for the appearance of thoroughness, restate the code, or inline what a link would carry.
- Never document assumptions — verify against the source; if uncertain, say so rather than invent.
- Never begin without the one-mode + one-reader + one-task gate satisfied.

---
*Standard Version: 1.0 — the shared documentation rubric. Built to by the docs-writer. Grounded in Diátaxis (the four modes + compass), Carroll's minimalism, and the Google / Microsoft / Write the Docs style canons. It does not define the docs-writer's conduct or report envelope (the agent body).*
