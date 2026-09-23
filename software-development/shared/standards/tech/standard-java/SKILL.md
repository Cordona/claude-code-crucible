---
name: standard-java
description: The single definition of idiomatic, modern Java — the shared language rubric java-developer BUILDS to and java-reviewer REVIEWS against. Applies whenever Java code is written, changed, or reviewed (Spring Boot, Micronaut, Quarkus, Jakarta EE, virtual threads). Defines modern language constructs, null safety, immutability, equals/hashCode/ordering contracts, concurrency, streams/collections, generics, exception/resource handling, type safety, framework idioms, JVM micro-performance, and static-analysis cleanliness. This is WHAT good Java looks like; it does NOT define the builder's workflow (build-core) or its own validation-gate specifics (java-developer), the reviewer's own category vocabulary and correctness-detective framing and scope-boundary table (genuinely java-reviewer's own), the base severity scale/handoff mechanism (review-core / review-report-standards), the universal concern rubrics (standard-clean-code/-self-documenting-code/-observability/-performance/-security/-persistence), or the build/report envelopes (build-report-standards / review-report-standards).
---

# Standard: Java

The **one** definition of idiomatic, modern Java. The `java-developer` builds to it; the `java-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we write Java and how we review it — a rule changed here moves both sides at once.

This skill defines **WHAT good Java looks like**. It is **NOT a Java tutorial** — assume fluent Java; it encodes only the non-default priorities and easy-to-miss traps. It deliberately does NOT contain: the builder's own workflow (`build-core`) or its validation-gate specifics — the compile/lint/test/build commands (`java-developer`); the reviewer's `category` vocabulary, correctness-detective framing, and its own scope-boundary table (genuinely `java-reviewer`'s own) or the base severity scale and handoff mechanism (`review-core` / `review-report-standards` — `java-reviewer` only maps its own categories onto that scale); the universal concern rubrics — `standard-clean-code`, `standard-self-documenting-code`, `standard-observability`, `standard-performance`, `standard-security`, `standard-persistence` (this skill covers only what is *language-level* Java); or the build/report envelopes (`build-report-standards` / `review-report-standards`).

**Baseline:** assume **Java 21 LTS** unless told otherwise. Apply modern idioms, null-safety, immutability-first, and thread-safety **by default**.

## 1. Modern language constructs

- **Records** for immutable data carriers (DTOs, value objects); compact constructors for validation. Prefer over mutable POJOs (Plain Old Java Objects) / Lombok `@Data`.
- **Sealed types** for closed hierarchies, driving **exhaustive `switch`** (compiler-checked — no `default` that silently swallows a newly added variant). Prefer pattern matching / record patterns over `instanceof` chains.
- Use **`java.time`** — never `Date`/`Calendar`, and never a shared `SimpleDateFormat` (not thread-safe; use `DateTimeFormatter`).
- A `switch` on a reference needs a `case null` or it throws a `NullPointerException` (NPE).

## 2. Null safety

- `Optional<T>` for **return types only** — never fields or parameters; prefer `map`/`orElseThrow` over `isPresent`/`get`.
- `Objects.requireNonNull(x, "…")` preconditions; `@Nullable`/`@NonNull` on public API; enable NullAway / Checker Framework where available.

## 3. Immutability

- `final` fields by default; `List.of`/`Map.of` for immutable collections, `List.copyOf` for defensive copies; no setters — builders or `with*` methods returning new instances.

## 4. Contracts: equals / hashCode / ordering

- `equals` and `hashCode` must be **consistent** — a broken pair corrupts `HashMap`/`HashSet`.
- `Comparable`/`Comparator` must define a **total order**.
- **JPA (Java Persistence API)/entity `equals`/`hashCode` derive from a stable business/natural key, NOT the generated id** — identity built on the generated id breaks across the transient→persistent transition.

## 5. Concurrency & thread-safety

- **Virtual threads are the default for new I/O-bound work (Java 21+):** one per task, no pooling. Keep **CPU-bound** parallelism on platform threads / a sized pool.
- On **Java ≤23**, avoid `synchronized` on a virtual-thread path (thread **pinning**) — use `ReentrantLock`. **JEP 491 resolves pinning in Java 24+**, so this is version-scoped, not an absolute law.
- `StructuredTaskScope` for related tasks — **preview API** (`--enable-preview`; reworked in Java 25+); use only on explicit request.
- Prefer immutability + message passing. For shared mutable state: `ConcurrentHashMap`/atomics; `final` fields; no **check-then-act** without atomicity; ensure **visibility** (`volatile`/happens-before on shared flags). Never use **mutable static fields** for shared state.
- Concurrent use of `ArrayList`/`HashMap` → `ConcurrentHashMap` and friends.
- Give every `CompletableFuture` an **explicit executor** and handle failure; never abandon it. Shut down every `ExecutorService` (leak otherwise).
- Guard against **deadlock** via consistent lock-acquisition order.
- `ThreadLocal` in virtual-thread code needs care (child inheritance).
- `SimpleDateFormat`/`Calendar` thread-safety is §1's rule, not restated here.

## 6. Streams & collections

- Declarative transforms + method references; **no side effects in `forEach`**; parallel streams only when measured. Return `List<T>` (the interface), accept the widest type; `EnumSet`/`EnumMap` for enum keys.

## 7. Generics

- No **raw types** — always parameterize. PECS (`? extends` producer / `? super` consumer) for flexible APIs.

## 8. Exception handling

- No over-broad `catch (Exception)` / `catch (Throwable)`; do not ignore checked exceptions; do not use exceptions for control flow. (Swallowed/empty catch → `standard-observability`'s log-or-throw rule.)

## 9. Resource handling

- Streams / connections in **try-with-resources**; close every `ExecutorService`; ensure cleanup on the **error path**.

## 10. Type safety

- No **unchecked casts** (`(List<String>) obj` without a check). Raw-type avoidance is §7's rule and the sealed-hierarchy/pattern-match idiom is §1's, neither restated here.

## 11. Framework idioms (Spring illustrative — map to the actual stack)

These are language-level framework rules, not app design:

- **Constructor injection** — never field `@Autowired`.
- `@Transactional` on **services** (not controllers/repositories), `readOnly = true` for queries; beware **self-invocation** bypassing the proxy.
- JPA associations **LAZY** by default; loading a lazy association outside the transaction throws `LazyInitializationException`; eager fetch on collections is a fetch-strategy defect.
- `@Valid` at controller boundaries (Jakarta Bean Validation).
- `@RestControllerAdvice` + `ProblemDetail` for error responses (leakage of internals → `standard-security`).

## 12. JVM micro-performance (language-level)

- Autoboxing in hot paths; `+` string concatenation in loops (→ `StringBuilder`/`String.join`); `Pattern.compile` inside a loop; missing collection capacity hints. *(Algorithmic scaling is `standard-performance`, not this.)*

## 13. Static-analysis cleanliness

- Code compiles clean under `-Xlint:all`; every `@SuppressWarnings` carries a written justification; SpotBugs / Checkstyle / Error Prone / NullAway findings are defects, not noise.
