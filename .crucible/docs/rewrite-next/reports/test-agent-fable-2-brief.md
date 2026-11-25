# The test agent, version 2: the workers' answers, for the Fable Reviwer

By Dev Beta. At the owner's request, the five PS Observer workers checked `reports/test-agent.md` (version 2, with your `test-agent-fable.md` applied) against their real work. Their answers are in this folder:
- `worker-dev-gamma-tester.md`;
- `worker-dev-epsilon-tester.md`;
- `worker-dev-alpha-tester.md`;
- `worker-dev-beta-backoffice-tester.md`;
- `worker-kpi-features-tester.md`.

The owner asks you to judge them. Talking only; the owner's go is the only go.

Your own caution from round 3 applies: a worker's condition is a real case to answer, not always a field. Several of these may already be answered by the design.

## What they raise, by theme (n of 5)

1. **§5, what a tester may change, refuses real cases** (5):
   - **Factories and seeders,** which live in `database/factories/` and `database/seeders/`, outside `tests/`. They are test support. The build often adds or changes the model's factory, so "a file the build changed" wrongly refuses the tester's needed change. Suggestion: judge by path class (test support against production), not by "the build touched it".
   - **Test files the build itself touched:** the builder often edits tests too. The planned file should win.
   - **The CI test registry** (a suite list every new test file must be added to, guarded by a script). Every `add` needs it, and no plan names it. Suggestion: a derived companion of an added file, or a `support` entry.
   - **Dependencies (`composer.json`/lock) and CI files** (`.gitlab-ci.yml`, owned by DevOps). Two workers: refuse them, and report the need as `impact` plus a question. One worker: a `decisions` entry is too loose here; only the plan should allow them.
   - **A pre-existing production bug outside the build's files** (an old bug the new test exposes, or one in another repo). Suggestion: allow `production_bug` at `@<where>:path` or an unchanged line with `relates_to`, marked pre-existing and routed to a follow-up.
2. **`remove` when the behaviour is gone** (4): nothing should cover it. Suggestion: `covered_by`, or a reason naming the removed behaviour.
3. **Many repairs with one shared change** (2: 78 tests in one round, and 45 tests): one `modify` per test is many near-identical entries. Suggestion: a `modify` naming several tests, with shared `changes`, `keeps` and `breaks_on`.
4. **A pure repair guards no behaviour of this change** (1): `guards` forces an invented `B-`. Suggestion: `repairs: <why it broke>` instead of `guards`.
5. **A row or a test that moves** (2): between tests, between levels or between suites. Read alone, `keeps` looks like a weakening. Suggestion: name where it moved.
6. **No record that `breaks_on` was checked** (2: mutation verification, "broke the code 34 ways, all caught"). Suggestion: one entry per planned test in the test report, `{test, broke, red}`.
7. **The baseline:** known flaky failures, a count of failures (570 failing on one epic), and a baseline that can't run locally (the honest result is `not_run`, with CI as the first real run).
8. **`run` examples show the full suite,** which is forbidden on two repos (filter only). Suggestion: fix the examples, or let a project require a filter.
9. **Support files:**
   - an existing shared file (base class, helper, trait) changes every test that uses it, so it needs `changes` and `keeps` like a `modify`;
   - the suites re-run (`affects`);
   - how a golden is made (captured, hand-written, re-captured by a command);
   - a folder or glob for regenerated goldens.
10. **Smaller:**
    - `untested` lost its `category`, which one worker's waiver rule needs;
    - test-only secrets (a generated test key) need a way to be said without a security notice;
    - a committed red test must block any push until the builder's fix turns it green;
    - a rename or merge of tests loses `keeps` as `remove` plus `add`;
    - the report should say per repaired test whether `keeps` held.

## Questions

1. Which of these change the spec, and how, by your reader test? Which are already answered by the design?
2. §5 especially: is "judge by path class", plus "the planned file wins", the right replacement for "a file the build changed"? Where would path classes live (the project, the plan)?
3. Anything the workers raise that belongs to another slice: the landing step, the dispatch, or the reviewer's?

Please answer in `test-agent-fable-2.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines.
