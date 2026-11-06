---
name: standard-testing
description: The single definition of a good test suite — the rubric tests-developer BUILDS to and lens-test-quality-reviewer REVIEWS against, in any language. Applies whenever tests are authored or a test-authoring approach is reviewed — never bound by a `{tech}-developer`, which build-core structurally forbids from touching test files. Does not define builder workflow (build-core) or lens-test-quality-reviewer's own scoring machinery.
---

# Standard: Testing

The **one** definition of a good test suite. `tests-developer` builds to it; the `lens-test-quality-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we build tests and how we review them — a rule changed here moves both sides at once. (No `{tech}-developer` binds this skill — every one of them is banned from ever writing or editing a test file, per `build-core`'s Constraints, so a pure authoring rubric has nothing for them to act on. The testability guidance they DO need — clear boundaries, no hidden state, dependency injection — lives in `build-core` itself, not here.)

This skill defines **WHAT good looks like**. It deliberately does NOT contain: the builder's workflow (that is `build-core`), or the reviewer's scoring machinery — severity, `category` vocabulary, scope-boundary/handoff, and false-positive guards live in the lens.

## The short list

The standard at a glance. Each line points at the section that defines it.

1. **Tests behavior, end to end** — through the feature's real entry point, compared against golden fixtures holding realistic payloads, responses, and entities (§1, §4, §7).
2. **Every test earns its place** — it guards a behavior no other test at its level guards (§0).
3. **Smallest set, never below the required categories** — only enough tests to guard what the change adds or alters; code guarding security, persisted data, concurrency, or authentication always gets a test, unless the human waives it (§0).
4. **End-to-end first, then integration, then unit** — at least one end-to-end test wherever the feature has an entry point to drive; an integration test where a real boundary we own must be exercised and no end-to-end test observes it; a unit test only when neither can observe the behavior, or when the human opts in (§4).
5. **One test per branch** — several inputs in one test, not a micro-test per input (§4).
6. **Existing files first** — a new test file or harness needs a stated reason (§0).
7. **Can fail** — every test is shown to fail when its behavior breaks (§2).
8. **A bug fix gets a test that fails on the old code** (§2).
9. **The name is the spec** — scenario and expected outcome (§3).
10. **Errors are behavior** — test failure paths and check what the error says (§6).
11. **No mocks of our own code** — fakes only at external boundaries we don't control (§5).
12. **Golden hygiene** — normalize ids and timestamps; regenerate on purpose; read the diff (§7).

## Philosophy

- Tests are **executable documentation**: a reader should learn what the system does from them.
- **False confidence is worse than no tests.** A suite that passes regardless of whether the behavior works manufactures trust it hasn't earned.
- **Volume is a cost, not a virtue.** Every test is code to read, run, and maintain; a suite that is larger than the behaviors it guards slows every change and buries the tests that matter.

## 0. Minimal sufficient set

- Start from the **behaviors the change adds or alters** — new behavior and behavior that could break — never from the code's line or branch list. Each test guards named behaviors.
- **Every test guards a behavior no other test at its level guards.** Two tests that fail on exactly the same breakage are one test too many: merge them (a parameterized test) or delete one.
- **One test per branch or equivalence class.** Further examples on an already-pinned branch add no protection.
- **Existing tests count.** A behavior an existing test already guards needs no new test; a test the change breaks is repaired, and its repair is named; a test the change makes obsolete is deleted.
- **Prefer the existing test file and the project's test base** (base classes, request/assertion/fixture helpers). A new test file, harness, or live-server fixture is a cost every run pays (and, in compiled stacks, often a new build target); add one only with a stated reason.
- **Required categories — always tested, even under the smallest set, unless the human waives it** (at `flow-testing` §3d). Code that guards **security**, **persisted data**, **concurrency** (races, retries, compare-and-set, idempotency), or **authentication** gets a test that fails when the guard breaks. Smallness never removes one. A `not_tested` entry for such code carries that category; when it falls under two, security or authentication wins — the plan writers refuse an entry that names security or authentication under any other category.
- **Deliberately untested is a valid outcome — with proof.** Name the case, the reason, and the risk accepted, plus one line of `proof` that the risk is covered or absent ("Covered by test 3", a `file:line`) — or mark it `unproven`. "Not testable at level X" names the level where it can be tested. An accepted risk with a user-visible effect is behavior: it gets a test, or the human waives it explicitly.

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

**A bug fix's key test must fail on the pre-fix code.** If reverting the fix leaves the test green, it does not guard the bug.

## 3. Structure & naming

- **AAA** — Arrange (data/conditions), Act (invoke the behavior), Assert (verify the outcome). One clear behavior per test.
- **Name the scenario, not the mechanics** — the name should describe the case without reading the body:

| Good | Bad |
|------|-----|
| `should_reject_order_when_inventory_insufficient` | `test1` |
| `returns_empty_list_when_no_matching_users` | `testOrder` |
| `throws_validation_error_for_negative_quantity` | `itWorks` |

Prefer the project's established naming style (e.g. `should <behavior> when <condition>`).

## 4. Granularity & altitude — end-to-end first

A suite is built in three phases, and a plan lists its tests in that order: end-to-end, integration, unit.

**Phase 1 — end-to-end (the default).**
- **At least one end-to-end test wherever the feature has an entry point to drive** — an endpoint, a command, a consumer, a hook. It enters through that entry point, runs our own code for real, and asserts every observable outcome of the flow: the response or output, the persisted entity, the emitted message.
- One end-to-end test proves what a pile of unit tests would: if a payload goes in and the expected response comes out and the expected entity is stored, the whole path works. Error paths are end-to-end too — a bad input in, the expected error body out.
- Only external systems are replaced (§5); infrastructure we own runs for real, in containers where possible.
- The same flow asserted across **distinct observable channels** (response vs. persistence vs. message) is **not** duplication — it verifies distinct outcomes.
- A feature with no entry point to drive (a pure library function nothing calls yet) has no end-to-end test; say why, and name the level that does test it.

**Phase 2 — integration tests.**
- An integration test runs a slice of our code against a **real** database, service, or process — no mocks of our own code — without driving the whole feature through its entry point.
- Write one when the behavior crosses a real boundary we own and no end-to-end test can observe it: a repository's query against the real store, a retry or compare-and-set under real concurrency, a consumer handling a real message, a feature with no entry point yet.
- It states why no end-to-end test observes the behavior.

**Phase 3 — unit tests (the exception).**
- A unit test is written only when **no end-to-end or integration test can observe the behavior** (unreachable in test time, too many cases to drive through the flow, pure logic with no boundary) — and then it states why — or when the human explicitly opts in to an offered one.
- A unit test verifies **behavior or business logic**, never wiring, call sequences, or a mocked imitation of a flow.
- **Several inputs on one branch belong in one test** (parameterized / table-driven), not one micro-test per input. For invariant-shaped pure logic (parsers, encoders, math), a property-based test (QuickCheck/Hypothesis/proptest/jqwik) is the stronger form.
- A live harness (a real external server, a spawned client) is the most expensive kind of end-to-end test; use it only when a stub of the external system cannot observe the behavior.

## 5. Mocking discipline

- **Internal-collaborator mocks are forbidden** — they couple tests to implementation and defeat behavior testing. The aversion also covers ad-hoc domain **stubs/fakes**: do not swap a real domain collaborator for a hand-written double. **Rare exception:** only when the real collaborator is genuinely impossible to exercise in a test (non-deterministic hardware, a not-yet-built dependency, a destructive irreversible side effect) — and then document *why* at the mock. "It was easier/faster" is never that reason.
- A **framework-layer boundary swap via test config** (e.g. replacing an auth filter chain, minting real tokens) is acceptable — it is a boundary swap, not a mock of a domain collaborator.
- **External boundaries** (third-party HTTP, services you don't control, time/date, the file system when unavoidable): prefer, in order, **real → containers** (e.g. Testcontainers) **→ test config-swap → an HTTP stub server** (e.g. WireMock). Mock only what you genuinely cannot containerize or run. Prefer a fake (in-memory store, fake clock) over an interaction mock where it gives a truer test.
- If a test mocks the thing it is supposed to verify, it verifies nothing.
- **Dead test scaffolding** (a stub server with zero stubs, a mocking library on the classpath with zero usage) is a defect — it misleads readers about the boundary strategy.

## 6. Negative paths & coverage

- **Failure behavior IS behavior:** test invalid input, error responses, and exception paths — not just happy paths.
- When asserting an error, **verify the error's shape/body** (type, message contract, fields) — not merely a status code or that *an* error occurred.
- **Boundary & equivalence classes:** cover the classes that apply to the changed behavior — empty/null, zero, one, max/limit, off-by-one, negative, invalid-type are the candidates, not a checklist to run on every function.
- **Test your own logic, not the framework's** — do not write tests that merely re-verify framework or library behavior; test the code you wrote.
- **Coverage is behavior coverage, not line coverage.** Do not chase a percentage; verify that what matters is exercised. Untested behavior is a liability; a false-confidence test is worse.

## 7. Golden / snapshot assets

- **End-to-end tests compare against golden fixtures** — realistic request payloads in; expected responses, persisted entities, and emitted messages out — instead of hand-built field-by-field assertions. The same applies to any test whose result has a shape worth comparing as a whole.
- **Realistic means captured**: prefer a fixture captured from a real run, copied from a real schema, or recorded from a real exchange over a hand-written one; a hand-written golden states why nothing could be captured.
- Hand-written assertions are for what a fixture can't capture: a single scalar or boolean, a short literal string, a property, an error's type.
- A golden fixture is an assertion technique, not a test level.
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
- No dead code (naming and magic-literal discipline belong to `standard-self-documenting-code`, not restated here — this file's own naming rule, §3, is scoped to test identifiers/scenario names only).

## 10. Efficiency & altitude

- **Small but fast** — unit tests stay well under ~100ms so people actually run them.
- **Right altitude** — when a unit test is warranted (§4), it stays framework-free; do not boot a full context (`@SpringBootTest`-style) to exercise a pure function.
- **Ration context reboots** — per-test context-dirtying is a big speed tax; default to the cheapest lifecycle that stays correct unless stateful components genuinely leak between tests.

## Consistency with the project

Match the project's **established test conventions** (framework, assertion style, location/naming, base-class/helper hierarchy, fixture layout, how external dependencies are handled). Where the project consistently and deliberately tests otherwise, its convention is the local norm — but a convention that is simply wrong (e.g. pervasive false-confidence tests) is still a defect, not a standard to preserve.
