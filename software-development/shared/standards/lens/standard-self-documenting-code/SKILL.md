---
name: standard-self-documenting-code
description: The single rubric for comments, docstrings, and self-documenting code — bound by every developer and by the self-documenting-code lens reviewer alike. Applies to ALL code, production and test, in any language — no distinction, no exemption for either. Defines WHAT good looks like — naming as documentation, the comment classification, docstring expectations on a public surface, and comment-volume proportionality. Does NOT define structural quality (standard-clean-code owns SOLID/DRY/coupling/nesting/dead-code/layout), builder workflow (build-core), or review scoring/severity (the lens).
---

# Standard: Self-Documenting Code

The **one** definition of what a comment, docstring, or name is for. Every developer builds to it; `lens-self-documenting-code-reviewer` judges against it. Both bind this single skill, so there is no daylight between how we build and how we review — a rule changed here moves both sides at once.

**This applies uniformly to production code and test code.** There is no separate, looser standard for tests. A test file that "decorates" every assertion with a docblock is held to the exact same bar as a production module that does the same — the only thing that differs is which reviewer has jurisdiction over the file (`lens-self-documenting-code-reviewer` reviews comments/docstrings everywhere; structural quality and test-specific correctness are split elsewhere).

This skill does NOT contain: structural quality — SRP, DRY/YAGNI, coupling, nesting, dead code, file layout (`standard-clean-code`); the builder's workflow (`build-core`); the reviewer's scoring machinery (severity, `category` vocabulary, false-positive guards, the detective method — those live in the lens); or language-specific idioms beyond comment syntax (the `{tech}` developer/reviewer).

## Philosophy — burden of proof, not permission

A comment or docstring starts at **zero**. It is not "allowed unless excessive" — it is **absent by default, and earns its place only by clearing a specific test**: does this code, as written, genuinely fail to say what a rename, an extraction, or a named constant would say instead? If a better name or a clearer structure would make the comment unnecessary, write that instead of the comment.

This is not "never explain anything." Genuine intent — *why* a decision was made, not *what* the code does — is real information the code cannot always carry, and a good comment that states it is a net positive, not a compromise. The failure mode this standard exists to prevent is not "too much explaining" in the abstract; it's comments and docstrings used as a **substitute** for clarity, applied as a habit or a default rather than a deliberate, justified exception. Chasing "zero comments" as an end in itself is its own anti-pattern — it produces contorted code (absurdly compressed names, extractions that exist only to manufacture a place to hang a name, logic bent out of its natural shape) purely to avoid writing one sentence of genuine rationale. The target is genuine self-documentation, not comment-avoidance for its own sake.

## Self-Documenting Code

Make the code readable without prose — the name IS the documentation.

| Element | Standard | Example |
|---------|----------|---------|
| Functions | verb + noun, reveals the action | `validateUserInput()`, `calculate_total_price()` |
| Variables | describes the content | `activeUserCount`, `pending_orders` |
| Booleans | reads as a question | `isValid`, `has_permission`, `should_retry` |
| Constants | names the meaning (no magic numbers) | `MAX_RETRY_COUNT`, `DEFAULT_TIMEOUT_MS` |
| Classes/Types | noun, reveals responsibility | `OrderProcessor`, `UserValidator` |

**Never abbreviate to save typing** (`d`, `tmp`, `data2`) — a name that doesn't reveal intent is a defect even if the code compiles. **The felt need to write an explanatory comment is itself a signal** — before writing it, ask whether a rename or an extraction would let the comment's own words become the function/variable name instead. If yes, do that; the comment was standing in for a name the code was missing.

```
// BAD — restates the code
counter++; // increment counter
// GOOD — the name is the documentation
let activeSubscribers = users.filter(u => u.isActive && u.hasSubscription);
// GOOD — WHY, not what
// Service accounts bypass the normal auth flow, so skip the session check.
if (user.isServiceAccount) return true;
```

## Comment classification — what a comment may and may not be

A comment is warranted ONLY for: WHY a non-obvious decision was made · a genuinely non-obvious algorithm · an external constraint the code can't express · a minimal public-API contract · a regulatory requirement · an unresolved, owned `TODO`. Every comment falls in one bucket:

| Bucket | Definition | Verdict |
|--------|------------|---------|
| **REDUNDANT** | Restates the code; compensates for a bad name or an overlong unit; a changelog/journal entry (version control already owns this); a mandated comment written only because "every function needs one," not because this one does; a position marker or decorative banner; an attribution comment; commented-out code | remove it — fix the *code* (rename, extract, named constant) so it's unnecessary |
| **WHY / RATIONALE** | Explains what code cannot: a workaround + issue link, non-obvious ordering, a constant from an external spec, a deliberate deviation, a warning of a non-obvious consequence, an amplification of an easily-missed detail, a legal/regulatory notice, an owned `TODO` | keep |
| **FUNCTIONAL** | Changes behavior/tooling, not documentation — shebangs, license/SPDX headers, `// eslint-disable-*`, `@ts-expect-error`, `@ts-ignore`, `/// <reference>`, `# type: ignore`, `# noqa`, `# pragma: no cover`, `//go:build`, `//go:generate`, `//nolint`, `# shellcheck disable=…`, `@phpstan-ignore`/`@phpstan-ignore-next-line`, `@psalm-suppress`, `@Suppress(...)`, `// ktlint-disable`, `// CHECKSTYLE:OFF`/`ON`, `// NOPMD`, `#[allow(...)]`/`#[cfg(...)]`, framework-significant annotations | keep — it is not a comment in the documentary sense |
| **PUBLIC-API DOC** | A doc comment on a *published, consumed surface* (docs.rs, Javadoc, KDoc, TSDoc, PEP 257 docstring) | keep — it is a consumer contract, unless it only restates the signature |

Never write a comment that restates the code, never leave commented-out code, never leave an ownerless `TODO`. **Internal code — application or test — is held strictly** (redundant comments are removed by rewriting the code, not trimmed); a **public, consumed surface** keeps its doc comment as a consumer contract.

## Docstrings — public-surface default, principle only

The cross-ecosystem consensus is: **a docstring is expected at the public API boundary**; internal/private code is judged by the same WHY-not-WHAT bar as an inline comment, never exempted from scrutiny but also never mandated by rote. Three language-agnostic rules follow from that:

1. **A public, consumed surface documents its contract.** A function/method/class that code outside this module — or outside this codebase — depends on should state what a caller needs and cannot get from the signature alone: behavior, failure/error conditions, non-obvious constraints. An internal/private member is exempt from this requirement; it is judged by the ordinary comment bar above, never by a blanket "every member needs one" rule.
2. **Never restate what the language already says.** If the language's own type system, signature, or contract already expresses something (a return type, a nullability guarantee, an error channel), repeating it in prose is REDUNDANT — the same rule as any other comment, applied to a doc comment specifically.
3. **An illustrative example must justify itself.** Where the convention includes a worked example, one that merely demonstrates calling syntax with no rationale is decorative, not documentation — it should show a genuinely non-obvious usage or be omitted.

**The exact doc-comment syntax, which sections are conventional, and how strictly presence is enforced are a per-language/per-ecosystem convention — not this standard's job to enumerate.** That is the `{tech}` developer/reviewer's territory, the identical boundary `standard-clean-code`'s File Layout section already draws for per-language layout idioms: a `{tech}` pair is expected to already know its own ecosystem's doc-comment form and culture, and to apply these three principles through it. Where a language's own documented convention diverges from a principle above (a documented, official convention — not personal preference), the language's own convention governs; this standard is the language-agnostic floor, not an override of one.

## Comment volume — proportionality, independent of comment kind

Correctly classifying a comment as WHY/RATIONALE or PUBLIC-API DOC does not exempt it from a proportionality check — a docblock or comment block materially longer than the unit it documents is a **trigger to look**, the same relationship the function-length figure in `standard-clean-code` has to function size. This has **three** distinct failure shapes, each with its own bar — do not apply one's bar to another:

- **Volume (recurring pattern)** — the comment is materially longer than the unit it documents — roughly **2:1 or above** — and this **recurs** across 2+ functions/classes in the same diff. One long-but-isolated docblock, alone, is not yet systematic, regardless of its own ratio, as long as it stays below the extreme-instance bar below.
- **Extreme single instance (no precedent to borrow, calibrated from real incidents)** — no mainstream tool or paper has a clean threshold for this (checked: SonarQube's comment-density metric measures the opposite direction — too little documentation, not too much; PMD's `CommentSize` is a flat absolute-line cap known to false-positive, not a ratio; a 2015 Pylint proposal for exactly this ratio was never shipped). Calibrated instead from two real, reported incidents: a comment/docblock **at or above a 5:1 ratio to the code it documents, once the comment block itself exceeds roughly 8-10 lines** (the floor is a second, independent gate, not another way of stating the ratio — a short comment can clear the ratio alone without being a real problem: a 6-line comment over a 1-line field is already 6:1, but at only 6 lines it isn't yet substantial enough on its own to flag without the floor also being cleared), is flagged **on its own, with no recurrence required** — this is the bar a 20-30 line docblock over a single field declaration clears immediately.
- **Placement (duplication)** — the same fact is stated in 2+ places (a code comment and the commit message, a code comment and the PR/MR description). This does **not** need to recur across units — a single instance is already the pattern, because the problem is the duplication itself, not how many functions it touches. A fact stated once is proportionate; the same fact stated in the code, the commit message, the PR/MR description, and a review artifact is a placement problem even when every individual copy is accurate and correctly classified.

When a comment's content is genuinely load-bearing (a non-derivable external constraint, a framework bug workaround) but also duplicated elsewhere, keep the copy a future editor would need **at the point of editing this file with nothing else open**, and let the provenance narrative — why this design over the alternatives, what was tried first — live in the commit/PR, which is where "why was this built this way" is actually searched for.

---
*Standard Version: 1.1 — a full-content deep-audit lens review (the first time this file was read start-to-finish as one document rather than diff-hunks) found two issues: the frontmatter description's "docstring placement" collided with the unrelated "Placement (duplication)" bar name one section below — reworded to "docstring expectations on a public surface"; and the Volume (recurring) bar stated no threshold of its own, with its only numeric guidance (a "roughly 2:1-4:1" band) stranded inside the Extreme-single-instance bar's own bullet as a routing aside — gave Volume its own open-ended "roughly 2:1 or above" floor (not a re-import of the old closed band, which left 4:1-5:1 routed to neither bar), leaving Extreme-single-instance to state only its own 5:1 + line-floor gate. Same review found the lens body restating this standard's numeric bar in 4 places (a repeat of the exact layering violation `standard-clean-code` v1.2 already fixed once) — stripped from the lens, cited by name instead; see that file for the corresponding fix, no version bump here since the number itself didn't move.*
*Standard Version: 1.0 — the shared self-documenting-code rubric. Built to by developers (via `build-core`); reviewed against by `lens-self-documenting-code-reviewer`. Structural quality lives in `standard-clean-code`; performance in `standard-performance`; language idioms in the `{tech}` pair. Extracted from `standard-clean-code` (which owned this content through its own v1.0-1.2) into its own first-class standard, because the concern had outgrown being a subsection: it needed its own generation-time self-check, its own review-time aggregate pass, and — the reason for this extraction specifically — `standard-clean-code`'s own scope was "production code" by its own description, which structurally blocked `lens-test-quality-reviewer` from ever borrowing its comment rule for test files without violating that stated boundary. This version also folds in web-research findings, kept strictly technology-agnostic: the Clean Code / Fowler-Beck taxonomy sharpened the REDUNDANT/WHY buckets (journal/mandated/position-marker/attribution comments named explicitly as REDUNDANT subtypes); the docstring research (which did surface real per-language detail — Rust's required doc sections, Google TS's ban on restating types, Java/Kotlin/Python's accessor and private-method exemptions) was deliberately distilled into three language-agnostic principles rather than an enumerated per-language section, since naming specific ecosystems here would duplicate what every `{tech}` developer/reviewer already knows and cross the same boundary `standard-clean-code`'s own File Layout section already draws; and comment-density tooling research found no existing industry ratio precedent in either direction, so the new single-instance extreme-outlier bar (5:1, gated by an ~8-10 line floor) is calibrated from this framework's own two real incidents rather than borrowed authority — stated honestly in this footer rather than presented as borrowed consensus it isn't. Applies uniformly to production and test code — no distinction, closing the gap that let `lens-test-quality-reviewer` run with zero comment-discipline enforcement on test files.*
