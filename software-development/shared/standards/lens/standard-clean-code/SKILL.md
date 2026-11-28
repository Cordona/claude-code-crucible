---
name: standard-clean-code
description: The single rubric for structurally clean code, bound by developers and the clean-code lens reviewer alike. Applies whenever non-trivial PRODUCTION code is written, changed, or reviewed in any language — test code follows the equivalent, test-aware bar in `standard-testing` §9, not this skill directly. Defines WHAT good structure looks like — SRP (Single Responsibility Principle), small flat functions, DRY, low coupling, design for extension, no dead code, file layout. Grounded in SOLID, DRY/YAGNI, and the Law of Demeter. Does NOT define naming/comments/docstrings (standard-self-documenting-code), builder workflow (build-core), the lens's own category vocabulary (genuinely lens-clean-code-reviewer's own), the base severity scale/false-positive discipline (review-core / review-report-standards), performance (standard-performance), or language-specific idioms (the `{tech}` pair).
---

# Standard: Clean Code

The **one** definition of structurally clean code for **production** code. Developers build to it; `lens-clean-code-reviewer` judges against it — the test-file/comment-and-docstring routing is `review-boundaries`'s own table; bind it, don't re-derive it here. Both build-side and production review-side bind this single skill, so there is no daylight between how we build and how we review production code — a rule changed here moves both sides at once. **Test code is held to the same structural bar in spirit** — no looser tolerance for SRP/DRY/dead-code violations — but that bar is `standard-testing` §9's own, test-aware restatement of these principles, not literally this skill: `lens-test-quality-reviewer` binds `standard-testing`, not `standard-clean-code`. Changing a rule here does not automatically move the test-side bar; keep the two in sync by hand if a structural principle changes.

This skill defines **WHAT good structure looks like**. It does NOT contain: naming, comments, or docstrings (`standard-self-documenting-code` — the felt need for a comment is itself the signal this standard's own SRP/extraction rules exist to resolve); the builder's workflow (`build-core`); the lens's own `category` vocabulary (genuinely `lens-clean-code-reviewer`'s own); the base severity scale, and universal finding-quality/false-positive discipline (`review-core` / `review-report-standards` — the lens only maps its own categories onto that scale); **performance** (its own `standard-performance`); or **language-specific idioms** (memory safety, async, framework conventions, per-language layout — the `{tech}` developer/reviewer).

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
- **KISS vs Open/Closed** — no seam for a variation that doesn't exist yet (above).
- **Decomposition vs flow** — extract to *name a concept* or *remove duplication*, not merely to hit a line count.

Judge by concrete harm — this repo's general false-positive discipline (`review-core` / `review-report-standards`), applied to structure specifically and not restated in full here. Clarity is the goal, not principle-compliance for its own sake.

## Clean Code consistency

Use the **project's existing structural conventions** — its own module boundaries, its own tolerance for function length and file size, its own abstraction layer names. Don't impose a foreign architecture. But a genuine SOLID/DRY/coupling violation with a nameable harm is a defect regardless of project convention; conformance never launders it.
