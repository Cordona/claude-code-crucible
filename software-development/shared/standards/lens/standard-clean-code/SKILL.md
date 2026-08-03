---
name: standard-clean-code
description: The single definition of clean, self-documenting, well-structured code — the shared rubric that developers BUILD to and the clean-code lens REVIEWS against. Applies whenever non-trivial production code is written, changed, or reviewed in any language. Defines self-documenting naming and the comment classification (redundant vs why vs functional vs public-API-doc), small/flat functions (SRP, guard clauses, nesting, parameters, no flag params), DRY with DRY-vs-YAGNI arbitration, low coupling (Law of Demeter, command-query separation, dependency injection), design for extension (OCP/LSP/ISP/DIP), no dead code, and file layout / ordering (the newspaper/stepdown rule). This is WHAT good looks like; it does not define builder workflow (build-core), review scoring (the lens supplies severity, vocabulary, and false-positive guards), performance (standard-performance), or language-specific idioms (the {tech} pair).
---

# Standard: Clean Code

The **one** definition of structurally clean, self-documenting code. Developers build to it; the `lens-clean-code-reviewer` judges against it. Both bind this single skill, so there is no daylight between how we build and how we review — a rule changed here moves both sides at once.

This skill defines **WHAT good looks like**. It does NOT contain: the builder's workflow (`build-core`); the reviewer's scoring machinery (severity, `category` vocabulary, false-positive guards, comment-hunting method — those live in the lens); **performance** (its own `standard-performance`); or **language-specific idioms** (memory safety, async, framework conventions, per-language layout — the `{tech}` developer/reviewer).

## Philosophy

Code should explain itself. A comment is a **last resort**, not a habit. Names carry the meaning; structure carries the intent.

## Self-Documenting Code

Make the code readable without prose — the name IS the documentation.

| Element | Standard | Example |
|---------|----------|---------|
| Functions | verb + noun, reveals the action | `validateUserInput()`, `calculate_total_price()` |
| Variables | describes the content | `activeUserCount`, `pending_orders` |
| Booleans | reads as a question | `isValid`, `has_permission`, `should_retry` |
| Constants | names the meaning (no magic numbers) | `MAX_RETRY_COUNT`, `DEFAULT_TIMEOUT_MS` |
| Classes/Types | noun, reveals responsibility | `OrderProcessor`, `UserValidator` |

**Never abbreviate to save typing** (`d`, `tmp`, `data2`) — a name that doesn't reveal intent is a defect even if the code compiles.

```
// BAD — restates the code
counter++; // increment counter
// GOOD — the name is the documentation
let activeSubscribers = users.filter(u => u.isActive && u.hasSubscription);
// GOOD — WHY, not what
// Service accounts bypass the normal auth flow, so skip the session check.
if (user.isServiceAccount) return true;
```

### Comment classification — what a comment may and may not be

A comment is warranted ONLY for: WHY a non-obvious decision was made · a genuinely non-obvious algorithm · an external constraint the code can't express · a minimal public-API contract in a library · a regulatory requirement. Every comment falls in one bucket:

| Bucket | Definition | Verdict |
|--------|------------|---------|
| **REDUNDANT** | Restates the code, or compensates for a bad name / an overlong unit | remove it — fix the *code* (rename, extract, named constant) so it's unnecessary |
| **WHY / RATIONALE** | Explains what code cannot: a workaround + issue link, non-obvious ordering, a constant from an external spec, a deliberate deviation | keep |
| **FUNCTIONAL** | Changes behavior/tooling, not documentation — shebangs, license/SPDX headers, `// eslint-disable-*`, `@ts-expect-error`, `@ts-ignore`, `/// <reference>`, `# type: ignore`, `# noqa`, `# pragma: no cover`, `//go:build`, `//go:generate`, `//nolint`, `# shellcheck disable=…`, framework-significant annotations | keep — it is not a comment in the documentary sense |
| **PUBLIC-API DOC** | A doc comment on a *published library surface* (docs.rs, Javadoc, godoc, TSDoc) | keep — it is a consumer contract, unless it only restates the signature |

Never write a comment that restates the code, never leave commented-out code, never leave an ownerless `TODO`. **Internal application code** is held strictly (redundant comments are removed by rewriting the code); a **public library surface** keeps its doc comments as a consumer contract.

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
*Standard Version: 1.0 — the shared clean-code rubric. Built to by developers (via build-core); reviewed against by lens-clean-code-reviewer. Performance lives in standard-performance; language idioms in the {tech} pair.*
