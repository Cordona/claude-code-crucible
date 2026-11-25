# Dev Beta [Backoffice]: the test agent against real test work

Read only. Sources: PSWS-1728, 1815, 1987, 2100, 2168, 2219 (Laravel, PHPUnit, tests on PHP 8.4 in Docker and 8.1 on the host).

## 1. Can a tester say everything?

Mostly yes. Two places where it can't:
- **A repair across many tests.** PSWS-1728 repaired 78 tests in one round. Many of them took the same change: `Log::spy` was replaced by a `MessageLogged` listener. One `modify` per test, each with its own `breaks_on`, means many near-identical entries. Suggest `modify.names: [...]` sharing one `changes`, `keeps` and `breaks_on`. `keeps` must stay per entry where it differs.
- **A golden re-capture.** PSWS-1815 re-captured 6 Keycloak goldens, using a run with an update-golden env var. `support.what` says what a golden holds, not how it is made or that a run rewrote it. Suggest an optional `support.from` (captured / hand-written / re-captured by `<command>`). The challenger needs that to judge whether a golden just mirrors the code.

`known_failures`, two `where`s and `run[]` now cover what round 1 asked for.

## 2. The per-action table

- **`remove.covered_by` must allow "the behaviour is gone".** PSWS-2100 deleted a setting and PSWS-2219 removed a whole matview. When a ticket deletes a behaviour, nothing covers its tests, and nothing should. Suggest `covered_by` or `gone: "<the change that removed it>"`.
- **`modify` without `level`: fine.** We never re-levelled a test.
- **`add` and `modify`: right.** `keeps` is the field that matters most on a repair, as in round 1.

## 3. §5, what a tester may change: what it wrongly refuses

| Real case | What §5 does | Why it's wrong |
|---|---|---|
| **PSWS-2168:** the build added a model, and its factory test needs `use HasFactory` on that model, a test seam on a production file | refused: a file the build changed | the seam isn't a bug, so `production_bug` is the wrong answer. Suggest a `seam` blocker kind that hands the one-line change back to the builder, or allow a planned `support` entry on a build file with the challenger's OK |
| **PSWS-2168:** `database/factories/KnownFeatureFlagFactory.php` lives outside `tests/` | allowed only if planned or in `decisions` | fine; the planner must know factories count as `support`. Say so in the briefing |
| **PSWS-1728:** a new shared concern `tests/Concerns/CapturesThrowables.php`, and a level argument added to a shared assert in the base `TestCase` | allowed if in `support` | right. A base-class change reaches every test that uses it, so the challenger should see the callers. Suggest `support.reaches: n` |
| **`phpunit.xml`:** we changed it once to make tests run in Docker (env, DB connection) | allowed via `decisions` | right; it should be `support` when planned |
| **A test dependency in `composer.json`/`composer.lock`** when the build also changed composer (not yet seen here; likely on any ticket adding a package) | refused: a file the build changed | wrongly refused. Composer files mix runtime and dev sections. Suggest a hunk check: allow `require-dev` changes, or route it like the seam |
| **CI files (`.gitlab-ci.yml`)** | via `decisions` | we never changed CI in test work; our CI file never calls PHPUnit itself. No real case |

**The `impact` example** ("the test suite now needs ext-pcntl in CI") is right: such a change is reported, not made by the tester.

Nothing else would bite.
