# Dev Gamma (Core API, PHP/Laravel): the test agent against real test work

Sources: the PSWS-2355 and PSWS-2356 test plans and their runs (partner action dates). Each run used a `--filter` in docker, with a worktree mounted.

## 1. Can a tester say everything? Almost. Three gaps

- **There is no record that `breaks_on` was checked.** The plan says what makes each test fail, but the test report has no field saying the tester broke the code and saw the test go red. v1 required that check (mutation verification). Without it, a test that passes no matter what reaches review looking the same as a real one. Add one entry per planned test, for example `{test, broke: "<what>", red: true}`.
- **A known flaky failure.** On this repo the `ActionGroupFactory` unique-value collision fails now and then, through no fault of the change (job 62566 on CI). `gate_red` blames the tests. Allow a known-failure list in `baseline`, or a `known` flag on a failing test, so the next job isn't sent to fix something nobody broke.
- **The `run` examples run the full suite** (`./vendor/bin/phpunit`, in the `no_tests` example). On core-api that is forbidden: the full suite takes hours and the rule is `--filter` only. Let a project mark `run` as filter-required, or at least don't model the full suite as the norm.

## 2. The per-action table

`add` is right. `modify` and `remove` each miss one real case.

- **A row that moves between tests.** The 2355 repair moved a `-05:00` row out of the accepted-input data provider and into the refusals test. The accepted test then no longer "keeps every row". Read alone, its `keeps` reads as a weakening, and the challenger can't tell. Let `changes` name the receiving test, for example `moves_to: T-4`, so the challenger sees the row went somewhere.
- **Extending with rows is our most common action** (all three 2355 tests). As a `modify` whose `keeps` lists every row, it works. Keep it.
- **`remove` with no `covered_by`.** Sometimes the behaviour is gone on purpose, and nothing should cover it. Allow `covered_by` or a `reason` naming the removed behaviour.
- **`level` only on `add`:** fine.

## 3. §5, what a tester may change: the wrong refusals

**Refused, but shouldn't be:**
- **A factory the build changed.** Laravel factories live in `database/factories/`, outside `tests/`. They are test support. A build that adds a column often touches the model's factory, and the tester then needs a new factory state in that same file. The rule "a file the build under test changed" refuses it, with a `production_bug` line that is wrong. Classify by path class (test support versus production), not by "the build touched it". The same goes for `database/seeders` used only by tests.
- **A pre-existing production bug.** `production_bug` must sit at a line the build changed, but a new test often exposes an old bug elsewhere. A reviewer's note on the 2355 MR (a year-0 `due_date` gives a 500) was in a file the build hadn't touched. That should be allowed, marked pre-existing, and routed to a follow-up, not refused.
- **Regenerated goldens.** 2355 edited 3 existing golden files and 2356 added one, all planned, which is fine. When a response shape changes, a regenerate run touches every golden of that endpoint. One `decisions` entry per file is noise. Let `support` name a folder, or a glob with a count.

**Allowed with a `decisions` entry, which is right as specified:** the shared `tests/TestCase.php` and its traits; `phpunit.xml`; `.env.testing`.

**Should stay refused, or be routed to the human:**
- **`composer.json` / `composer.lock` for a `require-dev` dependency.** The lock file churns a lot, and the builder may already have touched `composer.json`, which would refuse it for the wrong reason. Treat a dependency as an `impact` plus a question, not a silent edit.
- **CI files (`.gitlab-ci.yml`).** DevOps owns them here. Refuse them, and report the need as `impact`, as your `ext-pcntl` example does.

## 4. Smaller points

- **`baseline.where: php8.4` assumes the tester can run the baseline.** Here the local image is PHP 8.1 without ext-redis, while main needs 8.3. The honest baseline is `not_run` with that note, and the plan gate should then say that CI is the first real run.
- **§8, a plan changed after approval must be approved again:** yes. It matches what happened on 2356, where the plan changed after the challenge.

---
*Compiled by Claude Code Crucible Framework on behalf of Ventsislav Stoevski*
