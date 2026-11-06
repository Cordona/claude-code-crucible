# Testing: review

- **A repaired assertion that now targets intentionally changed behaviour is no weakening:** confirm the change was intended.
- **Never demand a clock abstraction where the test asserts no time.**
- **A project that tests its own way, consistently:** raise the tension once; don't flag every instance.

## Severity

A test finding is MEDIUM by construction: the code works today, and a test gap raises the risk of the next change.

- **CRITICAL:**
  - none for this lens.
- **HIGH:**
  - none for this lens (see Overrides).
- **MEDIUM:**
  - a false-confidence test (passes regardless, tautological, asserts a mock's return);
  - a repaired assertion that stopped verifying its original behaviour;
  - missing coverage of a critical or happy-path behaviour in the change, or of an important edge or error path;
  - a planned test missing, or not exercising its planned break; a test not in the approved plan;
  - an internal-collaborator mock; an implementation-coupled, brittle test;
  - a god test class, copy-pasted setup not extracted, or another single-responsibility break;
  - a flaky test, or a fixed `sleep` to await async work or prove a negative;
  - an order-dependent test or leaked shared state; a wall-clock or otherwise non-deterministic time assertion;
  - conditional logic in a test body;
  - an unnecessary or redundant test, or micro-case sprawl (delete or merge it);
  - a test at the wrong level: a unit test where an end-to-end or integration test covers it, a unit test of wiring, no end-to-end test where the feature has an entry point, or a live harness where a stub would observe it.
- **LOW:**
  - a missing error-body assertion (a status-only negative test);
  - a full-context boot for pure logic, or an unjustified context reboot;
  - a missed golden-asset opportunity, or a brittle inline assertion;
  - poor test naming, weak as documentation;
  - a deviation from the project's test conventions;
  - homogeneous stacked assertions without descriptive messages;
  - dead test scaffolding (an unused stub server or mocking library).

**Overrides:**
- Never grade a gap HIGH for its own importance.
- "Worse than no test" and "flakiness erodes CI trust" are true, but neither ships a defect to a user: they stay MEDIUM.

**What moves a level:**
- A full-context boot and an unjustified context reboot rise to MEDIUM when they slow the suite.
- A missing error-body assertion, a missed golden asset, a brittle inline assertion, poor naming and a convention deviation rise to MEDIUM when the cost is real for this suite.
