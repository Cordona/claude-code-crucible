---
name: language-kotlin
description: "Kotlin rules: toolchain, null safety, data classes, coroutines, Flow, Java interop and lints, plus the developer's verification gate. Use when writing or reviewing Kotlin on the JVM. A language plugin. Its gate writes only the build tool's output and its caches; needs Gradle or Maven and a JDK. Not for Kotlin driven only from another file (a Dockerfile `RUN`, a CI step), Android or Kotlin Multiplatform, or rules every language shares (`code-developer`, standard plugins)."
disable-model-invocation: true
user-invocable: false
metadata:
  label: Kotlin
---

# Language: Kotlin

The rules that are specific to Kotlin. Every role receives this file in its first message. A developer then receives `references/development.md` right after it: what to report, the defaults, the edge cases and the verification gate. A reviewer receives `references/review.md` right after it instead: how to judge a finding and how to grade it.

## Scope

- **In:** Kotlin on the JVM, built with Gradle (Kotlin DSL or Groovy) or Maven: libraries, applications, services and CLIs.
- **In:** Kotlin on a web framework with no plugin of its own, such as Ktor.
- **Out:** Kotlin driven only from another file, such as a Dockerfile `RUN ./gradlew build` line or a CI step.
- **Out:** Android, Kotlin Multiplatform, Kotlin/Native and Kotlin/JS: this file holds no rules for them.

## Toolchain

Settle it before writing a line. Take each fact from the first source below that sets it:

1. The build tool: its wrapper (`gradlew`, `mvnw`); else the build file present, `settings.gradle(.kts)` or `build.gradle(.kts)` for Gradle, `pom.xml` for Maven.
2. The JVM target: `kotlin { jvmToolchain(N) }` in the Gradle build; in Maven, the `kotlin-maven-plugin`'s `jvmTarget`.
3. The Kotlin version: the Kotlin plugin's version in the build or in the version catalog (`gradle/libs.versions.toml`); in Maven, the `kotlin.version` property.
4. What the project's own docs on its Kotlin code say, where the task's context lists them.
5. Otherwise Kotlin 2.0 on JVM 21 (see Version ledger).

## Null safety

- **Non-null by default:** `T?` only when null means something.
- **Never `!!`:** use `requireNotNull(x) { "…" }`, `?.let`, `?: return` or `?: throw`.
- **`firstOrNull` and `getOrNull` over `first` and `[]`.**
- **Fail fast at boundaries:** `require()` for arguments, `check()` for state.
- **Java platform types are nullable:** validate them at the boundary, since the compiler forces no null check on them.
- **`as?` over `as`.**
- **A `lateinit` read before initialization throws.**

## Data modeling and immutability

- **`sealed class` or `sealed interface` for state machines and results,** each driving an exhaustive `when`.
- **Use `when` as an expression,** so the compiler enforces exhaustiveness: an `else` silently swallows a newly added variant.
- **`val` over `var`, always.**
- **Read-only `List` and `Map` by default,** mutable only when needed.
- **Never expose a `MutableList` or other mutable state.**
- **A `@JvmInline value class` is zero-overhead only in direct form:** it boxes when nullable, generic or in a collection, which negates the benefit.
- **`kotlinx.serialization`: register sealed and polymorphic subtypes.**
- **`kotlinx.serialization`'s `encodeDefaults` is off by default,** so default values are not emitted: enable it when the consumer needs them.

## Data class contracts

A broken contract defeats an invariant or corrupts a hash structure, whatever the style:

- **`copy()` re-runs `init {}` but bypasses factory and private-constructor checks:** put invariants in `init {}`, so `copy()` re-checks them.
- **`@ConsistentCopyVisibility` aligns `copy()`'s visibility** with a non-public constructor; the Kotlin version it needs is in the Version ledger.
- **No `equals` or `hashCode` over an `Array` field:** `Array` uses reference equality; use `contentEquals` or a `List`.
- **No `equals` or `hashCode` over a mutable field:** it breaks hash-code stability once the object sits in a hash structure.

## Coroutines

- **Structured concurrency only, never `GlobalScope`:** it leaks work past the enclosing lifecycle.
- **`coroutineScope` for parallel decomposition;** `supervisorScope` when a child's failure must not cancel its siblings.
- **`async` and `await` for parallel results,** `launch` for supervised fire-and-forget.
- **An exception in `launch` propagates to the parent at once.**
- **A child `async` failure cancels the parent at once:** only a root `async` defers its exception to `await`, so a child `async` failure is never "handled at `await`".
- **Cooperate with cancellation:** check `ensureActive()` or `isActive` in long loops, and clean up in `finally` or `.use {}`.
- **Never block on `Dispatchers.Default`,** which is for CPU work: wrap blocking I/O in `withContext(Dispatchers.IO)`. A Loom or virtual-thread-backed dispatcher is fine for blocking work.
- **No `runBlocking` on a production request or suspend path, or inside a coroutine:** it blocks a thread and can deadlock or starve the pool. Bridge with a proper scope instead.
- **`withTimeout` on network and I/O calls that can hang.**

## Flow

- **Cold streams are `Flow`:** `flowOn` shifts the upstream dispatcher, `catch` handles upstream errors, and `buffer` or `conflate` give backpressure.
- **Collect a `Flow` on the right dispatcher.**
- **Hot streams are `StateFlow` or `SharedFlow`, with `replay` and `onBufferOverflow` set on purpose:** a wrong buffer suspends the emitter or silently drops events, both bugs.

## Java interop

- **An API that Java calls carries `@JvmStatic`, `@JvmOverloads` and `@Throws`** where each applies.

## JVM micro-performance

- **No primitive boxing on hot paths:** `Int?` and boxed generics box.
- **No needless `toList()` or `toMutableList()` copies.**
- **`asSequence()` for large or multi-stage chains:** each eager stage allocates a full intermediate list.
- **`inline` on hot lambda-taking functions:** otherwise each call with a capturing lambda allocates an object.

## Idioms

- **Pick the scope function that fits the intent** (`let`, `run`, `apply`, `also`, `with`), nested at most one deep.
- **Extension functions for domain behaviour,** never to reach private state.
- **`@DslMarker` on a builder's receiver type:** without it, an outer receiver's members leak into a nested lambda. A DSL builder missing it is an implicit-receiver collision defect, not a style nit.

## Kotlin mechanisms for the shared standards

- **Secrets:** `internal` visibility is no security control, since it still compiles to accessible bytecode.
- **Supply chain:** the Gradle version catalog, and OWASP Dependency-Check.
- **Logging:** SLF4J with structured fields and MDC.
- **Metrics and tracing:** Micrometer or OpenTelemetry.
- **Coroutine dispatcher pools:** sized on purpose, never unbounded.
- **Docs:** KDoc on a public item only when its signature can't state a constraint, a failure condition or behaviour beyond it, such as a threading or `internal`-boundary contract.
- **Migrations:** Flyway, in expand-contract steps.

## Lints

- **Compile with no new warning:** treat each one your change adds as a gate failure. Old ones in an existing project would otherwise fail every change.
- **Honor `detekt` and `ktlint` where the project configures them,** with no new finding.
- **Name each finding by its rule id:** a finding with no id can't be matched against the baseline the gate compares to.
- **Every `@Suppress` carries its written reason:** a reasoned one on a line complies, an unexplained one is a defect, and a rule turned off or down in the project's lint config is a defect too.

## Version ledger

| Fact | Value | Last verified |
|---|---|---|
| Default Kotlin version (Toolchain step 5) | 2.0 | not verified by a command: the legacy default, kept on 2026-10-30 |
| Latest stable Kotlin | 2.4.21 | 2026-10-30, `brew info --json=v2 kotlin`, macOS 27.2 |
| Default JVM target (Toolchain step 5) | 21 | not verified by a command: the legacy default, kept on 2026-10-30 |
| `@ConsistentCopyVisibility` available from | Kotlin 2.0 | not verified by a command: the legacy value, kept on 2026-10-30 |
