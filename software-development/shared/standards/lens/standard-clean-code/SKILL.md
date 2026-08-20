---
name: standard-clean-code
description: The single rubric for structurally clean code, bound by developers and the clean-code lens reviewer alike. Applies whenever non-trivial code — production or test — is written, changed, or reviewed in any language. Defines WHAT good structure looks like — SRP, small flat functions, DRY, low coupling, design for extension, no dead code, file layout. Does NOT define naming/comments/docstrings (standard-self-documenting-code), builder workflow (build-core), review scoring/severity (the lens), performance (standard-performance), or language-specific idioms (the tech pair).
---

# Standard: Clean Code

The **one** definition of structurally clean code. Developers build to it; `lens-clean-code-reviewer` judges against it for production code. Both bind this single skill, so there is no daylight between how we build and how we review — a rule changed here moves both sides at once. **This applies uniformly to production and test code** — there is no separate, looser structural bar for tests (comment/docstring discipline is a separate concern, entirely owned by `standard-self-documenting-code`).

This skill defines **WHAT good structure looks like**. It does NOT contain: naming, comments, or docstrings (`standard-self-documenting-code` — the felt need for a comment is itself the signal this standard's own SRP/extraction rules exist to resolve); the builder's workflow (`build-core`); the reviewer's scoring machinery (severity, `category` vocabulary, false-positive guards — those live in the lens); **performance** (its own `standard-performance`); or **language-specific idioms** (memory safety, async, framework conventions, per-language layout — the `{tech}` developer/reviewer).

## Small & Flat

- **One responsibility per unit (SRP)** — a function does one thing; a class has one reason to change.
- **Short functions** — roughly ≤20–30 lines; extract when a function grows a second job. (A cohesive function that does one thing is fine even if long — the figure is a trigger to look, not a hard limit.)
- **Guard clauses first** — handle edge cases at entry and return early; don't wrap the body in nested `if`s.
- **Max ~3 levels of nesting** — deeper is a signal to extract.
- **Minimal parameters** — prefer ≤3; bundle related args into an object/struct.
- **No flag parameters** — a boolean that switches a function between two behaviors is two functions wearing a trenchcoat; split them.

## DRY (with the YAGNI counter-weight)

Extract duplicated logic into one named unit and call it from every site. If you're about to copy-paste a block and tweak it, that block wants to be a function.

**But do not over-abstract.** Two similar-looking blocks that change for *different reasons* are NOT duplication. Extract an abstraction only when there are **2+ real, present** use cases that genuinely **co-change** — prefer a little duplication over the wrong abstraction. This is the DRY↔YAGNI arbitration: state, for each extraction, what is gained and what is paid.

## Low Coupling, Clear Boundaries

- **Law of Demeter** — talk to your immediate collaborators, not their internals. Avoid `a.getB().getC().doThing()` message chains; ask the collaborator to do the work.
- **Command-Query Separation** — a method either does something (command) or answers something (query), not both. No hidden side effect behind an innocent-looking getter (a genuine builder/accumulator is not a violation).
- **Depend on abstractions** — inject collaborators; don't reach into another module's concretes or hidden globals.

## Design for Extension (OCP / LSP / ISP / DIP)

- **Open/Closed** — when a `switch`/`if` chain branches on a type tag and grows with every new case, prefer polymorphism/strategy so a new case is a new type, not another edit to the chain. (But don't add extension seams for a variation that doesn't exist yet — KISS beats speculative OCP.)
- **Liskov** — a subtype/implementation must honor its supertype's contract: don't override a method to throw where the base doesn't, narrow the inputs it accepts, or weaken what it guarantees.
- **Interface Segregation** — no fat interfaces forcing clients to depend on methods they don't use; no unused method stubs.
- **Dependency Inversion** — depend on abstractions, not concretes `new`-ed deep in business logic.

## No Dead Code

Ship only code that runs. No unused functions, parameters, imports, or unreachable branches "kept just in case" — version control is the safety net. Dead code misleads the next reader.

## File Layout & Ordering (read top-down, like a newspaper)

Order every file so a reader meets the high-level intent first and the details after — the **stepdown / newspaper** rule:

- **Public / entry-point declarations first**, private helpers after.
- **Private helpers in the order they are first called** (caller before callee) — following the flow never requires jumping backward.
- **A wrapper before the function it wraps**; leaf utilities last.
- Group a type with the code that immediately consumes it.

This is a readability **default, not an absolute**: where a language's semantics force a different order — e.g. a `const`/closure that must be declared before the site referencing it (temporal-dead-zone / forward-reference rules) — follow the language. The specific **per-language layout idioms** (tests module placement, constant-block placement, import ordering, member-order conventions) live in the `{tech}` developer/reviewer, not here — this rule is the language-agnostic principle they realize.

## Arbitrating competing principles

These principles pull against each other; a good judgment names the trade-off:
- **DRY vs YAGNI** — no abstraction below 2+ real present use cases (above).
- **KISS vs Open/Closed** — no extension seam for a variation that doesn't exist yet.
- **Decomposition vs flow** — extract to *name a concept* or *remove duplication*, not merely to hit a line count.

Judge by concrete harm: if you cannot name the harm a structure causes (a change made harder, a bug hidden, a test blocked), it is clean enough — clarity is the goal, not principle-compliance for its own sake.

---
*Standard Version: 1.3 — extracted naming/comments/docstrings out entirely into the new first-class `standard-self-documenting-code` (Philosophy, the naming table, comment classification, and the proportionality rule all moved there — that standard's own footer records the extraction rationale in full). This standard's own scope was widened at the same time: "production code" became "production or test, no distinction," since SOLID/DRY/coupling/nesting/dead-code/layout apply identically to test code and there was never a real reason to say otherwise — `tests-developer` already bound this skill before this version. Note: `lens-clean-code-reviewer` still hands off ALL test files to `lens-test-quality-reviewer` as of this version — closing the review-side gap for test-file structural quality (binding this standard to `lens-test-quality-reviewer` and having it score structural findings on test files directly) is a disclosed, planned follow-up, not yet wired. A new `review-boundaries` row was added in the same round to route comments/docstrings/naming-as-documentation to `lens-self-documenting-code-reviewer` regardless of file type.*
*Standard Version: 1.2 — a consistency-lens finding on v1.1's proportionality rule found the two numeric judgment bars it implies (volume needs recurrence across units; placement fires on a single duplicated instance) were left unstated here and instead asserted directly in `lens-clean-code-reviewer`'s body — a layering violation, since this standard owns WHAT good looks like (including numeric bars, per the existing function-length precedent) and the lens is supposed to only cite it. Made both bars explicit here as two distinct failure shapes with two distinct thresholds; the lens now cites them instead of restating them.*
*Standard Version: 1.1 — a real-world consumer report (a PHP MR carrying a 1.9:1 and 2.3:1 comment-to-code ratio, rejected by the team that received it) found the comment-classification table governed comment KIND but never VOLUME: every line in the offending docblocks classified correctly as WHY, so the rubric licensed unlimited prose as long as it was individually justified. Added an explicit proportionality rule, mirroring the existing function-length heuristic, that applies even to correctly-classified WHY/PUBLIC-API DOC content, plus a cross-artifact-duplication signal (the same rationale surviving in the code, the commit, and the PR/MR is a placement problem regardless of any one copy's accuracy). The matching enforcement mechanism — an aggregate pass that isn't vetoed by the per-comment rewrite guard — lives in lens-clean-code-reviewer; the matching generation-time self-check lives in build-core.*
*Standard Version: 1.0 — the shared clean-code rubric. Built to by developers (via build-core); reviewed against by lens-clean-code-reviewer. Performance lives in standard-performance; language idioms in the {tech} pair.*
