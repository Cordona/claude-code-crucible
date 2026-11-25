# Worker answer: the test agent (core-api, KPI features)

Stack: PHP/Laravel, PHPUnit in Docker, one DB per tenant (tests swap in a test tenant DB), GitLab CI split into parallel suites. Cases below are from our real test commits (PSWS-935 import errors, PSWS-1030 KPI guards, PSWS-2236 completions, the CI test-registry work).

## 1. Can a tester say everything it needs?

Mostly yes. `impact`, `noticed`, `production_bug` and the red-test-still-committed rule all match real work. Gaps:
- **A blast radius for a shared helper.** When a tester changes `tests/Fixtures/*Helpers.php` or the base `TestCase`, the reviewer needs to know which other tests use it and whether they were re-run. Add an optional `affects` (the suites or filters re-run) on a `support` entry and on a `decisions` entry for a shared file. Otherwise a narrowed run "passes" while another suite breaks.
- **The baseline's known failures.** We never run the full suite, and a narrowed baseline can be red for a reason unrelated to the build (we've had tests freezing time in a data provider). `baseline` needs `failing` plus a way to say "known, not ours", or the gate rule forces a `gate_red` blocker that isn't a blocker.
- **`no_tests` example:** its `run` is `./vendor/bin/phpunit`, the full suite. That's forbidden here. Make `run` require a filter, or at least don't show the unfiltered form as the example.

## 2. The per-action table

Right for `add` and `modify`. Two tweaks:
- **`remove` needs a `why`** besides `covered_by`. Our real removals were dead duplicates (a file registered in two suites) and tests that never ran. There, `covered_by` is "itself, elsewhere" or nothing. Allow `covered_by: "none"` with a `why`.
- **`modify` without a level is fine,** but a modify that *moves* a test (unit to integration, or into another suite) has nowhere to say so. One optional `moves` text would do.

## 3. §5, what a tester may change: the real cases it wrongly refuses

1. **The CI test registry, every time.** CI runs only files listed in `tests/ParallelGroups/suite-N.txt`, and a guard script fails the pipeline for an unlisted test file. Every `add` of a new test file must also edit a suite list. A plan never names it, so §5 refuses it or makes it a "departure" on every single test job. Allow it as a derived companion of an added file (or let `support` hold it), not a decision.
2. **Laravel factories, which live in `database/factories/`, outside `tests/`.** They're test support. When the build added a model, it often added its factory too (PSWS-845 did). The rule "a file the build under test changed is refused" then blocks the tester from fixing or extending the factory it needs. Refuse only the build's *production* files, judged by path class, not every file in the build's commit.
3. **Test files the build itself touched.** Our own fix commits change code and tests together: the PSWS-935 fix touched 30+ production files, two test files and the suite registry. The same rule then refuses the tester's planned `modify` of a test the builder already edited. The planned file should win over the "build changed it" rule for test paths.
4. **Test config.** `phpunit.xml` `<env>` entries (we added a cache-companies setting for a test tenant). These are real and rare. `decisions` covers them, and that's fine.
5. **Shared helpers and base traits** (`tests/Fixtures/*Helpers.php`, the tenant-DB switching trait). Fine via `decisions`, but they need `affects` (§1 above).

Correctly refused, keep these:
- `.gitlab-ci.yml` (CI changes are DevOps/human; say it in `impact`);
- `database/migrations/` (schema is production: report a `production_bug` or a blocker);
- `composer.json` dev dependencies. On our stack a new extension or package means a new image the tester can't build, so it's a `question` or `impact`, never a silent edit.

One addition: **generated outputs.** Our test runs write about 25 `.xlsx`/`.csv` files into `storage/app/`, and they sit untracked. The tester's commit must never include them, and "a file neither in the plan nor in decisions" shouldn't fire on files the test run itself produced. Ignore untracked files that a test run creates under paths matched by `.gitignore` or a per-repo list.
