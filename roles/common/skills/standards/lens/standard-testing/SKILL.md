---
name: standard-testing
description: The single definition of a good test suite — the shared rubric that developers BUILD to and the test-quality lens REVIEWS against. Applies whenever tests are written, changed, or reviewed in any language. Defines behavior-through-the-public-contract testing, the false-confidence rule, AAA structure and scenario naming, mocking discipline (internal collaborators forbidden; boundaries via real→container→fake→stub), negative-path and boundary coverage, golden/snapshot masking, determinism and isolation (no fixed sleeps, no wall-clock coupling), test-code cleanliness, and coverage as an indicator. This is WHAT good looks like; it does not define builder workflow (build-core) or review scoring (the lens supplies severity, category vocabulary, and false-positive guards).
---

# Standard: Testing

The **one** definition of a good test suite. Developers build to it; the `lens-test-quality-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we build tests and how we review them — a rule changed here moves both sides at once.

This skill defines **WHAT good looks like**. It deliberately does NOT contain: the builder's workflow (that is `build-core`), or the reviewer's scoring machinery — severity, `category` vocabulary, scope-boundary/handoff, and false-positive guards live in the lens.

## Philosophy

- Tests are **executable documentation**: a reader should learn what the system does from them.
- **False confidence is worse than no tests.** A suite that passes regardless of whether the behavior works manufactures trust it hasn't earned.
- **Quality over quantity** — 5 meaningful tests beat 50 that assert nothing real.

## Framework-agnostic

Every framework/library named below is an **illustrative example** — map each concept to the target project's actual test framework. The concept exists in every ecosystem:

| Concept | Examples across ecosystems |
|---------|----------------------------|
| Parameterized / data-driven tests | JUnit `@ParameterizedTest`, pytest `parametrize`, Go table-driven, RSpec shared examples |
| Fake / controlled time | `Clock`/`InstantSource`, Python `freezegun`, JS fake timers, Go injected clock |
| HTTP boundary stub | WireMock, MSW (JS), `responses`/`respx` (Python), `httptest` (Go) |
| Golden / snapshot / approval | JSONAssert, Jest snapshots, `pytest-snapshot`, Rust `insta`, ApprovalTests |
| Real infra for tests | Testcontainers (any language), ephemeral local servers |
| Assertion messages | AssertJ `.as("…")`, pytest assert messages, testify messages |

## 1. Test behavior through the real public contract

Tests assert **observable outcomes through the code's real public contract** — never private/internal state or call sequences. What "the public contract" is depends on the code's shape:

- **Service / app:** end-to-end flows through HTTP, DB, queues, events.
- **Library:** its public API.
- **CLI:** its commands, exit codes, and output.
- **Pure logic:** inputs → outputs at the public function.

A test coupled to implementation detail — one that would break on a behavior-preserving refactor — is a defect.

## 2. No false confidence (the cardinal rule)

Every test must be able to **FAIL if the behavior breaks**. Self-check: *"Would this test FAIL if the behavior it claims to verify were broken?"* If not, it is false confidence. Defects:

- Tautological assertions (`assertTrue(true)`, asserting a constant, re-asserting a literal you just set).
- Asserting a **mock's own configured return** (circular — proves nothing).
- Assertions that don't constrain behavior (e.g. only `assertNotNull` on a rich result).
- "Coverage theater" — exercises code but verifies nothing meaningful.
- **Catch-and-ignore** — a `try`/`catch` that swallows the failure so the test passes no matter what.

## 3. Structure & naming

- **AAA** — Arrange (data/conditions), Act (invoke the behavior), Assert (verify the outcome). One clear behavior per test.
- **Name the scenario, not the mechanics** — the name should describe the case without reading the body:

| Good | Bad |
|------|-----|
| `should_reject_order_when_inventory_insufficient` | `test1` |
| `returns_empty_list_when_no_matching_users` | `testOrder` |
| `throws_validation_error_for_negative_quantity` | `itWorks` |

Prefer the project's established naming style (e.g. `should <behavior> when <condition>`).

## 4. Granularity & altitude

- **Test at the altitude of the public contract (§1).** For a **service/app**, prefer **flow / integration tests** through real boundaries. For a **library / CLI / pure logic**, testing the public API / commands / function directly *is* behavior testing — unit tests are legitimate and appropriate; do not force them into end-to-end tests.
- A unit test that **mocks collaborators to test a thin slice of *flow-shaped* code** usually should be an integration test.
- **Pure, side-effect-free logic** (mappers, formatters, resolvers, calculations) is legitimately unit-tested regardless of code shape.
- For **invariant-shaped pure logic** (parsers, encoders, math), prefer **property-based tests** (QuickCheck/Hypothesis/proptest/jqwik) — example-based tests miss the edge space properties cover.
- The same flow asserted across **distinct observable channels** (persistence vs. message published vs. response) is **not** duplication — it verifies distinct outcomes.
- **Redundant or low-value tests** should be removed — but the distinct-channels case above is not redundant.

## 5. Mocking discipline

- **Internal-collaborator mocks are forbidden** — they couple tests to implementation and defeat behavior testing. The aversion also covers ad-hoc domain **stubs/fakes**: do not swap a real domain collaborator for a hand-written double. **Rare exception:** only when the real collaborator is genuinely impossible to exercise in a test (non-deterministic hardware, a not-yet-built dependency, a destructive irreversible side effect) — and then document *why* at the mock. "It was easier/faster" is never that reason.
- A **framework-layer boundary swap via test config** (e.g. replacing an auth filter chain, minting real tokens) is acceptable — it is a boundary swap, not a mock of a domain collaborator.
- **External boundaries** (third-party HTTP, services you don't control, time/date, the file system when unavoidable): prefer, in order, **real → containers** (e.g. Testcontainers) **→ test config-swap → an HTTP stub server** (e.g. WireMock). Mock only what you genuinely cannot containerize or run. Prefer a fake (in-memory store, fake clock) over an interaction mock where it gives a truer test.
- If a test mocks the thing it is supposed to verify, it verifies nothing.
- **Dead test scaffolding** (a stub server with zero stubs, a mocking library on the classpath with zero usage) is a defect — it misleads readers about the boundary strategy.

## 6. Negative paths & coverage

- **Failure behavior IS behavior:** test invalid input, error responses, and exception paths — not just happy paths.
- When asserting an error, **verify the error's shape/body** (type, message contract, fields) — not merely a status code or that *an* error occurred.
- **Boundary & equivalence classes:** cover the standard classes — empty/null, zero, one, max/limit, off-by-one, negative, invalid-type — not just the happy value.
- **Test your own logic, not the framework's** — do not write tests that merely re-verify framework or library behavior; test the code you wrote.
- **Coverage is behavior coverage, not line coverage.** Do not chase a percentage; verify that what matters is exercised. Untested behavior is a liability; a false-confidence test is worse.

## 7. Golden / snapshot assets

- For output with a stable, reviewable shape (serialized documents, rendered files, API payloads), compare against a committed **golden/expected** asset instead of sprawling hand-built assertions.
- **Mask or normalize non-deterministic fields** (ids, timestamps, versions) before comparing, so the test fails only on a real change.
- Regenerate goldens deliberately and review the diff — never blind-accept.

## 8. Deterministic & isolated

- **Order-independent & self-seeding** — each test sets up and tears down its own state; no test depends on another running first; no leaked shared mutable state.
- **No flakiness** — an intermittently failing test destroys trust; fix it or delete it.
- **No fixed `sleep()`** to await async work or to "prove a negative." Prefer an **early-returning bounded poll**, a real signal (blocking consume, latch), or a library like Awaitility. *(A bounded poll that returns early on success is fine — only fixed-duration sleeps are a smell.)*
- **No wall-clock coupling** — inject a clock (`Clock`/`InstantSource`); do not assert against `now()` with a tolerance window.
- **Shared-resource hygiene** — with reused containers/resources, reset data per test AND isolate per test (e.g. unique consumer groups, earliest offset); never assume a pristine broker/DB.

## 9. Test code = production-grade clean code (test-aware)

Test code is real code — hold it to the same structural bar, with test-aware tie-breakers:

- **DRY the mechanics:** extract shared setup, fixtures, loaders, seeders, clients, base classes, data builders/object-mothers into **test helpers** — do not copy-paste infrastructure. BUT keep each test's **intent local and readable**; do not hide intent behind indirection. Data-driven parameterization is the DRY tool for repeated scenarios, NOT a DRY violation.
- **SRP:** one test verifies one behavior/scenario; no god-test asserting many unrelated things. (A flow test asserting several outcomes of ONE flow is fine.)
- **No conditional logic in test bodies** — `if`/`for`/`while`/`try-catch` that drives which assertions run means you cannot know what was verified. *(A uniform `forEach { assert … }` over a collection is fine — that is not branching.)*
- **Diagnosable failures** — a red test names what broke, not just "expected true." When assertions are homogeneous or stacked, use descriptive messages (e.g. `.as("…")`), or replace a long run of bare assertions with a single golden STRICT compare.
- Meaningful names, no magic literals (use constants or asset files), no dead code.

## 10. Efficiency & altitude

- **Small but fast** — unit tests stay well under ~100ms so people actually run them.
- **Right altitude** — pure, side-effect-free logic stays a no-framework unit test; do not boot a full context (`@SpringBootTest`-style) to exercise a pure function.
- **Ration context reboots** — per-test context-dirtying is a big speed tax; default to the cheapest lifecycle that stays correct unless stateful components genuinely leak between tests.

## Consistency with the project

Match the project's **established test conventions** (framework, assertion style, location/naming, base-class/helper hierarchy, fixture layout, how external dependencies are handled). Where the project consistently and deliberately tests otherwise, its convention is the local norm — but a convention that is simply wrong (e.g. pervasive false-confidence tests) is still a defect, not a standard to preserve.

---
*Standard Version: 1.0 — the shared testing rubric. Built to by developers (via build-core); reviewed against by lens-test-quality-reviewer.*
