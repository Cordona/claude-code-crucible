# Dev Epsilon (Auth API): the test agent vs real test work

Source: auth-api (PHP 8.1, Laravel 9, PHPUnit, about 1,100 tests, run in a docker image; the worktrees have no vendor directory). Test work for PSWS-1792, 1793, 1794, 1951 and 2294.

## 1. Can a tester say everything in its reports?

Mostly. Five gaps:

- **Mutation verification has no home.** A real report read: "broke the production code in 34 ways, every break was caught", done in scratch copies. The test reviewer relied on it. Add a gate or field: breaks tried, breaks caught, where they ran.
- **A repair needs an answer per test.** 1951 had 12 repairs, and 1793 repaired 9 PartnerKeyCheckTest cases. For each planned `modify`, the report should say whether `keeps` held (`held`, or `changed: why`). Otherwise the guard against weakening is only checked at plan time.
- **A baseline needs a count.** 1951 started with about 570 failing epic tests. A `failing` list works, but the card needs a number, plus the failing group or file.
- **A red commit from a `production_bug` stays local.** Our MR pipeline runs the unit tests on every MR. Say that a committed red test blocks any push until the builder's fix turns it green.
- **A `production_bug` outside the build's files is refused.** A new test can expose a wrong line in unchanged code the change relies on, or in core-api. Allow `@<where>:path` and an unchanged line with `relates_to`, as the review report does, or route it to `noticed`.

## 2. The per-action table

`add` and `remove` are right. On `remove`, allow `covered_by: "nothing: <why>"`. 1951 removed about 65 tests whose code the restore deleted.

`modify` has three problems:

- **A pure repair guards no behaviour in this plan.** 1793's 9 repairs broke because the shared base class and stub changed, while the behaviour stayed the same. A `guards` list that must name a `B-` in the plan makes the tester invent a behaviour. Allow `repairs: <why it broke>` in place of `guards`, or a `B-` marked `unchanged`.
- **There's no rename or merge.** 2294 merged two drafts into one renamed test. With only `remove` + `add`, `keeps` is lost. Add `new_name` on `modify`, or a `replaces: [T-…]` on `add` that keeps `keeps`.
- **`support` has no action.** An existing shared file can change every test that uses it. 1793's commit changed `tests/Feature/PartnerApiTestCase.php` by about 100 lines. When the file exists, a `support` entry should carry `changes` and `keeps`, as `modify` does.

## 3. §5, what a tester may change

The rule that refuses "a file the build under test changed" is too broad. It should refuse only the build's production (non-test) files.

| Real case | §5 today | Should be |
|---|---|---|
| A test file the build also changed, e.g. a test it touched to keep its own gates green, or a data fixture it updated | refused | allowed: a test path is never "the code it tests" |
| A shared base class or helper (`PartnerApiTestCase.php`, 1793) | allowed if in `support`; refused if the build touched it | allowed, with `changes` / `keeps` (point 2) |
| JSON test data and route snapshots under `tests/files/` (1793 changed `partner-routes.json`) | allowed if planned | right |
| `phpunit.xml` env or the base `TestCase.php` (PSWS-114 changed both for Redis) | refused if the build changed it | allowed when planned: test config |
| A dev dependency in `composer.json` + `composer.lock` (the build changed these on 2320) | refused if the build changed it; otherwise a `decisions` entry is enough | allowed only when it's in the approved plan's `support`: a new dependency is a supply-chain change the human approves |
| CI (`.gitlab-ci.yml`; our "run unit tests on MRs" was its own commit) | a `decisions` entry is enough | refused: CI affects everyone's pipeline, so it's a builder or human job; the tester reports it in `impact` |
| A seam in production code (a clock seam) | refused | right: use `untested`, or a builder job |
| `config/*.php` or `.env.example` for a test value | refused | right: tests set config in code |

So §5 has two errors:
- **Too strict on test paths the build touched.**
- **Too loose on dependencies and CI.** For those, a `decisions` entry shouldn't be enough; only the approved plan should allow them.
