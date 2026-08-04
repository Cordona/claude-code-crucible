---
name: standard-kotlin
description: The single definition of idiomatic, correct Kotlin — the shared language rubric that the kotlin-developer BUILDS to and the kotlin-reviewer REVIEWS against. Applies whenever Kotlin code is written, changed, or reviewed (JVM services, Spring Boot Kotlin, Ktor, coroutines, Flow, Exposed, kotlinx.serialization, KMP). Defines null-safety discipline, data-class/copy() invariant semantics, value-class boxing, coroutines & structured concurrency, Flow/StateFlow/SharedFlow configuration, equals/hashCode contracts, when exhaustiveness, scope-function discipline, sealed hierarchies, immutability, extension functions, Kotlin-over-Java idioms, and the Spring/JPA compiler-plugin needs. This is WHAT good Kotlin looks like; it does not define builder workflow (build-core), the reviewer's correctness-detective method / scope-boundary / severity / category vocabulary (the kotlin-reviewer), or the build/report envelopes (build-report-standards / review-report-standards).
---

# Standard: Kotlin

The **one** definition of what good, correct Kotlin looks like. The `kotlin-developer` builds to it; the `kotlin-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we write Kotlin and how we review it — a rule changed here moves both sides at once.

This skill defines **WHAT good looks like** — the idioms to reach for and the traps to avoid. It is **NOT a Kotlin tutorial**: assume fluent Kotlin, and encode only the non-default priorities and easy-to-miss pitfalls. It deliberately does NOT contain: the builder's workflow (`build-core`) or the reviewer's machinery — the correctness-detective method, scope-boundary/handoff, severity, and `category` vocabulary live with the `kotlin-reviewer`; report envelopes live in `build-report-standards` / `review-report-standards`.

Assume **Kotlin 2.0 / JVM 21** unless the project states otherwise.

## Null Safety

- Non-nullable by default; `T?` **only** when null is semantically meaningful.
- **NEVER `!!`** — use `requireNotNull(x) { "…" }`, `?.let`, `?: return` / `?: throw`; prefer `firstOrNull` / `getOrNull` over `first` / `[ ]`.
- `require()` (arguments) / `check()` (state) at boundaries — fail fast.
- **Treat platform types from Java interop as nullable** — validate at the boundary; they are dangerous because the compiler will not force a null check.
- Prefer `as?` (safe cast) over `as`; a `lateinit` read before initialization throws.

## Data Modeling & Immutability

- `data class` for value objects; `sealed class` / `sealed interface` for state machines / results → drive an **exhaustive `when`** (prefer `when` as an *expression* so the compiler enforces exhaustiveness; an `else` can silently swallow a newly-added variant).
- **`val` over `var`, always**; immutable `List` / `Map` by default, mutable only when genuinely required; do not expose `MutableList` / mutable state.
- `@JvmInline value class` for type-safe wrappers — zero-overhead **only in direct form**; it **boxes when nullable, generic, or used in a collection**, which negates the benefit.
- **`copy()` re-runs `init{}` but bypasses factory / private-constructor validation.** Put invariants in `init{}` so `copy()` re-checks them; a guard living only in a factory behind a private constructor is defeated by `copy()`. Use **`@ConsistentCopyVisibility` (Kotlin 2.0)** to align `copy()`'s visibility with a non-public constructor.
- `equals` / `hashCode` with an `Array` field or a mutable field is a contract trap — `Array` uses reference equality (use `contentEquals` / a `List`), and a mutable field breaks the hashCode-stability contract once the object is in a hash structure.
- `kotlinx.serialization`: register sealed / polymorphic subtypes; `encodeDefaults` is **off** by default (default values are not emitted) — enable it when the consumer needs them.

## Coroutines & Structured Concurrency

- **Structured concurrency only — never `GlobalScope`** (it leaks work past the enclosing lifecycle). `coroutineScope` for parallel decomposition; `supervisorScope` when a child failure must NOT cancel its siblings. `async` / `await` for parallel results, `launch` for supervised fire-and-forget.
- **Exception propagation:** exceptions in `launch` propagate to the parent immediately. A **root** `async` defers its exception to `await`, but a **child** `async` inside a plain `coroutineScope` still **cancels the parent immediately on failure** — do not wave a child-`async` failure through as "handled at `await`."
- **Cooperate with cancellation** — check `ensureActive()` / `isActive` in long loops; clean up in `finally` / `.use {}`.
- **Dispatchers:** `Dispatchers.IO` for blocking I/O, `Dispatchers.Default` for CPU work — **never block on `Default`**; wrap blocking calls in `withContext(Dispatchers.IO)`. (A Loom / virtual-thread-backed dispatcher is fine for blocking work — coroutines remain the concurrency model.)
- **No `runBlocking` in production request / suspend paths or inside an existing coroutine** — it blocks a thread and can deadlock or starve the pool; bridge with a proper scope instead.
- Wrap network / IO in `withTimeout` where a hang is possible.

## Flow

- `Flow` for cold streams — `flowOn` to shift the upstream dispatcher, `catch` for upstream errors, backpressure via `buffer` / `conflate`; collect on the correct dispatcher.
- `StateFlow` / `SharedFlow` for hot streams — set **`replay` / `onBufferOverflow` deliberately**. A misconfigured buffer means a suspending emitter or silently-dropped events, both of which are bugs.

## Idioms

- Scope functions (`let` / `run` / `apply` / `also` / `with`) — pick the right one for the intent, and **nest ≤1 deep**.
- **Extension functions** for domain behavior — not to reach private state.
- **Kotlin properties**, not Java-style getters / setters; avoid needless `companion` statics.

## Java Interop (when exposed to Java)

- `@JvmStatic` / `@JvmOverloads` / `@Throws` for Java-friendly APIs.
- Treat incoming platform types as nullable — stricter null checks at the interop boundary.

## Kotlin/JVM Micro-Performance (language-level)

- Avoid primitive boxing in hot paths (`Int?` and boxed generics box); avoid needless `toList()` / `toMutableList()` copies; use `asSequence()` for large / multi-stage chains; add `inline` on hot lambda-taking functions.

## Framework Notes (Spring / JPA with Kotlin)

- Enable the **`kotlin-spring` (all-open)** and **`kotlin-jpa` (no-arg)** compiler plugins — Kotlin classes are `final` with no no-arg constructor, which otherwise breaks CGLIB proxies and JPA entities.

## Static Analysis

- Compile with `-Werror`; no unjustified `@Suppress`. Honor `detekt` / `ktlint`.

---
*Standard Version: 1.0 — the shared Kotlin rubric. Built to by the kotlin-developer (via build-core); reviewed against by the kotlin-reviewer.*
