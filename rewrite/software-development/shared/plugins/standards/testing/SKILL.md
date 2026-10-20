---
name: standard-testing
description: Test rubric for any language — tests that can fail, required tests, proven gaps, smallest set, public contract, end-to-end first, mocking, failure paths, goldens, isolation, tie-breakers, speed. Injected into the agent's first message when loaded. Writes nothing. Not for production code (its plugins), test structure (standard-clean-code), comments and other names (standard-self-documenting-code), or store or security rules (standard-persistence, standard-security).
disable-model-invocation: true
user-invocable: false
metadata:
  label: Testing
---

# Standard: Testing

What a good test suite holds, in any language. A test that can't fail is worse than no test: a suite that passes whether or not the behaviour works earns trust it hasn't got. Volume is a cost: every test is code to read, run and maintain, so a suite larger than the behaviours it guards slows every change. Tests are executable documentation: a reader learns from them what the system does. The developer builds tests to these rules, then follows `references/development.md`; a reviewer (once `code-reviewer` exists) judges tests by the same rules, then follows `references/review.md`. Both receive this file in their prompt, with their role's reference file right after it.

## Scope

- **In:** the tests the developer writes or changes in a test dispatch, test data and fixtures included.
- **Following it writes only test files and test data:** a mutation or pre-fix check never edits, reverts or stashes a production file. Use the project's mutation-testing tool where one exists; otherwise name the mutation and the line it would change, and mark the check unproven.
- **Production code is out:** a dispatch that writes production code writes no tests, so its `PLUGIN` never names this standard; it would have nothing here to act on.
- **Waivers and opt-ins:** this standard says only when the human must give one (§2, §5).
- **Project conventions:** follow the project's test conventions: its framework, assertion style, test location and naming, base classes and helpers, fixture layout, and how it handles external dependencies. A deliberate, consistent convention is the local norm. A convention never excuses a wrong test: a test that can't fail is a defect even where the project's other tests do the same.

## Any framework

Read every rule below through this section. Each framework or library named here is an example only: map each concept to the project's own test framework, since the concept exists in every ecosystem.

| Concept | Examples |
|---|---|
| Parameterised or data-driven test | JUnit `@ParameterizedTest`, pytest `parametrize`, Go table-driven tests, RSpec shared examples |
| Fake or controlled time | `Clock` or `InstantSource`, Python `freezegun`, JS fake timers, a Go injected clock |
| HTTP boundary stub | WireMock, MSW, `responses` or `respx`, `httptest` |
| Golden, snapshot or approval | JSONAssert, Jest snapshots, `pytest-snapshot`, Rust `insta`, ApprovalTests |
| Real infrastructure for tests | Testcontainers, ephemeral local servers |
| Assertion messages | AssertJ `.as("…")`, pytest assert messages, testify messages |

## 1. Tests that can fail

- **Every test can fail when its behaviour breaks:** ask "would this test fail if the behaviour it claims to verify were broken?"; if not, it is false confidence.
- **No tautological assertion:** `assertTrue(true)`, asserting a constant, or re-asserting a literal just set.
- **Never assert a mock's own configured return:** it is circular and proves nothing.
- **Every assertion constrains behaviour:** only `assertNotNull` on a rich result constrains nothing.
- **No coverage theatre:** code exercised with nothing meaningful verified.
- **No catch-and-ignore:** a `try`/`catch` that swallows the failure passes whatever happens.
- **A bug fix's key test fails on the pre-fix code:** if reverting the fix leaves it green, it doesn't guard the bug.

## 2. Required tests and proven gaps

- **Code that guards security, persisted data, concurrency (races, retries, compare-and-set, idempotency) or authentication always gets a test that fails when the guard breaks, unless the human waives it:** smallness never removes one.
- **Name the category of a required-category behaviour left untested;** when it falls under two, name it security or authentication, never another. Its untested line needs the human's waiver (the rule above), noted in its reason.
- **Leave a behaviour untested only with proof:** name the case, the reason and the risk accepted, plus one line showing the risk is covered or absent (`test 3`, a `file:line`), or mark it unproven. Write each case as the one line `references/untested-template.md` sets; that file arrives in the developer's prompt after `references/development.md`. A reviewer gets no template: it checks each line holds the case, reason, risk, category and proof these two rules name.
- **"Not testable at level X" names the level where it can be tested.**
- **An accepted risk with a user-visible effect is behaviour:** test it, or the human waives it explicitly.

## 3. The smallest sufficient set

- **Start from the behaviours the change adds or alters** (new behaviour, and behaviour that could break), never from the code's line or branch list; each test guards named behaviours.
- **Every test guards a behaviour no other test at its level guards:** two tests that fail on exactly the same breakage are one too many, so merge them into a parameterised test or delete one.
- **One test per branch or equivalence class:** a further example on a branch already pinned adds no protection.
- **A behaviour an existing test already guards needs no new test.**
- **Repair a test the change breaks, and name the repair.**
- **Delete a test the change makes obsolete.**
- **Prefer the existing test file and the project's test base** (base classes; request, assertion and fixture helpers).
- **Add a new test file, harness or live-server fixture only with a stated reason:** each is a cost every run pays, often a new build target in a compiled stack.

## 4. Behaviour through the public contract

- **Assert observable outcomes through the code's real public contract, never private state or call sequences.** The contract follows the code's shape:
  - A service or app: end-to-end flows through HTTP, the database, queues and events.
  - A library: its public API.
  - A CLI: its commands, exit codes and output.
  - Pure logic: inputs to outputs at the public function.
- **A test coupled to implementation detail is a defect:** one that would break on a behaviour-preserving refactor.

## 5. Levels: end-to-end first

- **Build the suite level by level:** end-to-end first, then integration, then unit.

### End-to-end

- **At least one end-to-end test wherever the feature has an entry point to drive (an endpoint, a command, a consumer, a hook):** it enters there, runs the project's own code for real, and asserts every observable outcome of the flow (the response or output, the persisted entity, the emitted message). One such test proves what a pile of unit tests would.
- **Error paths are end-to-end too:** a bad input in, the expected error body out.
- **Replace only external systems (§6), systems the project doesn't control (a third-party HTTP API, a service it doesn't own, time and date, the file system where it can't be avoided):** infrastructure the project owns runs for real, in containers where possible.
- **The same flow asserted on distinct observable channels (response, persistence, message) is not duplication:** each verifies a distinct outcome.
- **A feature with no entry point to drive gets no end-to-end test,** such as a pure library function nothing calls yet: say why, and name the level that does test it.
- **A live harness (a local or containerised server standing in for an external one, a spawned client) is the costliest end-to-end test:** use one only when a stub of the external system can't observe the behaviour.

### Integration

- **Write an integration test when the behaviour crosses a real boundary the project owns and no end-to-end test can observe it:** a repository's query against the real store, a retry or compare-and-set under real concurrency, a consumer handling a real message, a feature with no entry point yet.
- **An integration test states why no end-to-end test observes the behaviour.**

### Unit

- **Write a unit test only when no end-to-end or integration test can observe the behaviour, and state why;** or when the human explicitly opts in to an offered one. The reasons: unreachable in test time, too many cases to drive through the flow, or pure logic with no boundary.
- **A unit test verifies behaviour or business logic,** never wiring, call sequences or a mocked imitation of a flow.
- **Put several inputs on one branch in one parameterised or table-driven test,** not a micro-test per input.
- **For invariant-shaped pure logic (parsers, encoders, math), a property-based test is the stronger form** (QuickCheck, Hypothesis, proptest, jqwik).

## 6. Mocks and boundaries

- **Never mock an internal collaborator, or swap a real domain collaborator for an ad-hoc stub or fake:** it couples the test to implementation and defeats behaviour testing.
- **The one exception: the real collaborator can't be exercised in a test** (non-deterministic hardware, a dependency not yet built, a destructive irreversible side effect); document why at the mock. "Easier" or "faster" is never that reason.
- **A framework-layer boundary swap through test config is acceptable** (replacing an auth filter chain, minting real tokens): it swaps a boundary, not a domain collaborator.
- **At an external boundary, prefer in order: containers, then a test-config swap, then an HTTP stub server;** mock only what can't be containerised or run.
- **Never run a test against a real external system:** a test run against a live system acts on it, and the developer never reaches a live environment.
- **Prefer a fake over an interaction mock where it gives a truer test.**
- **A test that mocks the thing it verifies verifies nothing.**
- **Dead test scaffolding is a defect** (a stub server with no stubs, a mocking library nothing uses): it misleads readers about the boundary strategy.

## 7. Failure paths and coverage

- **Test failure behaviour:** invalid input, error responses and exception paths, not only happy paths.
- **Assert an error's shape or body** (its type, message contract and fields), never only a status code or that some error occurred.
- **Cover the boundary and equivalence classes that apply to the changed behaviour:** empty or null, zero, one, max or limit, off-by-one, negative and invalid type are candidates, not a checklist for every function.
- **Test the project's own logic, not the framework's:** never re-verify framework or library behaviour.
- **Coverage means behaviour coverage, not line coverage:** never chase a percentage. Untested behaviour is a liability; a test that can't fail is worse.

## 8. Golden fixtures

- **End-to-end tests compare against golden fixtures** (realistic request payloads in; expected responses, persisted entities and emitted messages out), not hand-built field-by-field assertions; so does any test whose result has a shape worth comparing whole.
- **Realistic means captured:** prefer a fixture captured from a real run, copied from a real schema or recorded from a real exchange to a hand-written one; a hand-written golden states why nothing could be captured.
- **Capture a golden only from a local or containerised run,** never from a live environment.
- **Before saving a captured fixture, strip or replace every credential, auth header, token, cookie and piece of personal data with a placeholder:** a fixture never holds a real secret.
- **Hand-written assertions are for what a fixture can't capture:** a single scalar or boolean, a short literal string, a property, an error's type.
- **A golden fixture is an assertion technique, not a test level.**
- **Mask or normalise non-deterministic fields (ids, timestamps, versions) before comparing,** so the test fails only on a real change.
- **Regenerate goldens deliberately and review the diff;** never blind-accept.

## 9. Deterministic and isolated

- **Each test sets up and tears down its own state:** no test depends on another running first, and no shared mutable state leaks between tests.
- **No flaky test:** an intermittently failing test destroys trust; fix it or delete it.
- **No fixed `sleep()` to await async work or to prove a negative:** prefer an early-returning bounded poll, a real signal (a blocking consume, a latch) or a library such as Awaitility. A bounded poll that returns early on success is fine.
- **No wall-clock coupling:** inject a clock (`Clock`, `InstantSource`); never assert against `now()` with a tolerance window.
- **With reused containers or resources, reset data per test and isolate per test** (unique consumer groups, earliest offset); never assume a pristine broker or database.

## 10. Structure and naming

- **Arrange, act, assert** in every test, in that order.
- **One clear behaviour per test:** a test guarding two leaves a red run that doesn't say which one broke.
- **Name the scenario, not the mechanics:** the name describes the case without reading the body.
  - Good: `should_reject_order_when_inventory_insufficient`, `returns_empty_list_when_no_matching_users`, `throws_validation_error_for_negative_quantity`.
  - Bad: `test1`, `testOrder`, `itWorks`.
- **Prefer the project's established naming style,** such as `should <behaviour> when <condition>`.

## 11. Test-code tie-breakers

These settle where a test pulls against the general code-structure rules.

- **Extract the mechanics into test helpers** (shared setup, fixtures, loaders, seeders, clients, base classes, data builders), never copy-pasted infrastructure.
- **Keep each test's intent local and readable,** never hidden behind indirection.
- **Data-driven parameterisation is the tool for repeated scenarios,** not a duplication defect.
- **An end-to-end test asserting several outcomes of one flow is one behaviour;** a god-test asserting unrelated things is not.
- **No conditional logic in a test body:** an `if`, `for`, `while` or `try`/`catch` that decides which assertions run hides what was verified. A uniform `forEach { assert … }` over a collection is fine.
- **A red test names what broke,** not just "expected true": for homogeneous or stacked assertions, use descriptive messages (`.as("…")`), or replace a long run of bare assertions with one strict golden compare.
- **§10's naming rule covers only test identifiers and scenario names.**

## 12. Speed

- **Keep unit tests well under about 100 ms,** so people actually run them.
- **A warranted unit test stays framework-free:** never boot a full context (`@SpringBootTest`-style) to exercise a pure function.
- **Ration context reboots:** per-test context-dirtying is a big speed tax, so default to the cheapest lifecycle that stays correct, unless stateful components genuinely leak between tests.
