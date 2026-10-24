# Testing: development

Apply after `SKILL.md`'s rules, before writing tests.

## Reporting

`standard-code-development-report` sets each item's shape.

- **On a TEST dispatch, each untested line (in standard-testing's untested-template form), the mutation results and each repaired test** -> the report's TEST keys `untested`, `mutation` and `repaired`, the reviewer's only evidence that each gap is proven and each test can fail. The keys are reserved: never write them (a TEST dispatch does not run).

## Self-check before reporting

1. Every new or changed test was shown to fail under one real mutation of the behaviour it guards, and a bug fix's key test fails on the pre-fix code, with no production file edited, reverted or stashed: by the project's mutation-testing tool, or, where none exists, with the mutation and the line it would change named and the check marked unproven, as `SKILL.md` Scope sets. No assertion is tautological, circular on a mock or unconstrained; no test is coverage theatre or catch-and-ignore.
2. Every guard of security, persisted data, concurrency or authentication has a test that fails when the guard breaks, or the human waived it. Each behaviour left untested has its line in the untested template's form (follows this file in the plugin's block). Each accepted risk with a user-visible effect is tested, or the human waived it.
3. The tests start from the behaviours the change adds or alters. Each guards one no other test at its level guards, one per branch or equivalence class. Existing tests were counted: a broken one repaired and its repair named, an obsolete one deleted. A new test file, harness or live-server fixture has a stated reason.
4. Tests assert outcomes through the public contract, never private state or call sequences. Each entry point has an end-to-end test, error paths included, and a feature with none says why. Each integration and unit test states why no higher level observes the behaviour, or the human opted in to the unit test.
5. Only external systems are replaced, in the preference order, with no test run against a real external system, no mock of the project's own code and no dead scaffolding. Failure paths are tested and assert the error's shape. The boundary classes that apply are covered.
6. End-to-end results compare against goldens captured from a local or containerised run, with no real secret or personal data saved, non-deterministic fields masked and any regenerated golden's diff reviewed. Each test sets up and tears down its own state, with no fixed sleep, wall-clock coupling or shared-resource leak.
7. Each test is arrange-act-assert, one behaviour, named for its scenario, with the mechanics in helpers and no conditional logic in its body; a red test names what broke. Unit tests are fast and framework-free. The project's test conventions were followed, and none excused a test that can't fail.
8. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
