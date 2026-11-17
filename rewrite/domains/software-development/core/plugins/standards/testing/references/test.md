# Testing: test

## Reporting

- **The test plan follows `standard-code-test-report`'s plan contract;** each behaviour left untested is one entry of its `untested` list, in the untested template's object form.
- **The test report follows `standard-code-test-report` too:** `standard-code-build-report`'s build report, checked with `--kind test`, with the deltas `standard-code-test-report` sets.

## Mutations

- **Break only the behaviour a test guards, never an implementation detail, and only in the throwaway copy `mutation-copy.sh open` makes:** the whole worktree but `.git`, installed dependencies included. A pre-fix check reverts the fix there too, and the project's mutation-testing tool, where one exists, runs there.
- **Never break anything in the real worktree, and never use git stash, checkout or restore.**
- **Remove the copy with `mutation-copy.sh remove` before the stop,** which is refused while it exists.
- **A check that can't run in the copy is unproven** (the script missing or failing, or the test can't run there): an `open` item in the test report naming the test, the mutation, the line it would change and why.
- **A test that can't go red is fixed, or is a deviation as `standard-code-test-report` sets.**

## Self-check before reporting

1. Every new or changed test was shown to fail under one real mutation of the behaviour it guards, and a bug fix's key test fails on the pre-fix code, each break made as Mutations sets and the copy removed before the stop; a check that couldn't run in the copy is an `open` item, and a test that can't go red was fixed or is a deviation. No assertion is tautological, circular on a mock or unconstrained; no test is coverage theatre or catch-and-ignore.
2. Every guard of security, persisted data, concurrency or authentication has a test that fails when the guard breaks, or the human waived it. Each behaviour left untested has its entry in the untested template's object form. Each accepted risk with a user-visible effect is tested, or the human waived it.
3. The tests start from the behaviours the change adds or alters. Each guards one no other test at its level guards, one per branch or equivalence class. Existing tests were counted: a broken one repaired and its repair named, an obsolete one deleted. A new test file, harness or live-server fixture has a stated reason.
4. Tests assert outcomes through the public contract, never private state or call sequences. Each entry point has an end-to-end test, error paths included, and a feature with none says why. Each integration and unit test states why no higher level observes the behaviour, or the human opted in to the unit test.
5. Only external systems are replaced, in the preference order, with no test run against a real external system, no mock of the project's own code and no dead scaffolding. Failure paths are tested and assert the error's shape. The boundary classes that apply are covered.
6. End-to-end results compare against goldens captured from a local or containerised run, with no real secret or personal data saved, non-deterministic fields masked and any regenerated golden's diff reviewed. Each test sets up and tears down its own state, with no fixed sleep, wall-clock coupling or shared-resource leak.
7. Each test is arrange-act-assert, one behaviour, named for its scenario, with the mechanics in helpers and no conditional logic in its body; a red test names what broke. Unit tests are fast and framework-free. The project's test conventions were followed, and none excused a test that can't fail.
