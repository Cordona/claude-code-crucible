# Dev Alpha: the test agent vs real test work

Checked against `test-agent.md` (version 2). The evidence is ecosystem-api (PHP 8.4 / Laravel, phpunit feature tests against a real database) and the PSWS-1313, 1726, 1727, 1813 and 1948 commits. "GUESS" marks an inference. Read only.

**Caveat:** our commits are one per ticket, so a file in a ticket's commit may have been written by the builder or the tester; I can't tell which from git.

## 1. Can a tester say what real work needs?

Mostly yes. Five gaps:
- **A bug in a file the build didn't change.** `production_bug.at` must be a file the build changed. PSWS-1948 fixed Bugsnag baseline filters that an earlier ticket (1726) had broken in `config/bugsnag.php`. A tester on a later build that finds this gets refused.
  - Allow any production line, marked as found outside this change, like a review's `relates_to` or `out_of_scope`.
- **Mass repairs.** The uuid change on PSWS-1313 broke 45 tests, and lens fixes on PSWS-1813 broke 18. That's one `modify` per test, each with its own `keeps`. It's workable, but a repair entry naming several tests with one shared change and `keeps` would read better at the gate.
- **Shared data providers.** Our rows live in traits such as `ProvidesEditorNameInputs` and `ProvidesClientSuppliedUuids`. Adding a row there changes every test that uses it, but a `modify` names one test. A `support` entry should be able to say which tests a change reaches.
- **`untested` has no `category`.** The plan-shape review had one, and the waiver rule needs it. Our real untested cases were concurrency: the PSWS-1813 restore/destroy race came back from the AI review as HIGH.
- **Test-only secrets.** PSWS-1726 added a generated test-only encryption key to `.env.testing`, and PSWS-1948's fixtures held secret-shaped keys. The tester needs a way to say "test-only, generated, not real" without `security: true` or a held stop. The `support.what` text is a promise made before anything is captured (same as r1's `captured[]` point).

## 2. The per-action table

- **`add`:** right.
- **`modify`:** right. `keeps` is the field that mattered most on the 45 PSWS-1313 repairs.
- **`remove`:** `covered_by` can't be met when the behaviour itself is gone. Allow `covered_by` or a `why` saying the behaviour was removed by this change.
- **`level` on `add` only:** fine. Re-levelling a test is a remove plus an add.

## 3. §5: what it wrongly refuses

The rule "a file the build changed is refused" works at file level, but these files are shared by builder and tester. Real cases:

| File | Real case | Refused? |
|---|---|---|
| `database/factories/EditorFactory.php` | added in the PSWS-1313 ticket commit with the model. It's test infrastructure outside `tests/` | **wrongly**, if the build made it: a tester adding a factory state gets the `production_bug` line |
| `composer.json` / `composer.lock` | PSWS-1313's build added a runtime dependency. A tester's `require-dev` addition lands in the same files | **wrongly** |
| `.env.testing` | PSWS-1726 added a required env var. The tests need its test value here, and the builder may have written it with `.env.example` | **wrongly**, if the build touched it |
| `phpunit.xml` | PSWS-1727 raised the test `memory_limit` | allowed via `decisions`. Fine, it's a real departure worth showing |
| `tests/Feature/Concerns/*` traits and `tests/Support/*.php` subprocess scripts (concurrency tests) | 1726 added nine traits; 1727 modified `SendsCrossOriginRequests` | allowed via plan `support` or `decisions`. Fine |
| `storage/api-docs/*.json` (generated OpenAPI, asserted by `ApiDocsTest`) | the build regenerates it | correctly refused: a stale doc is a `production_bug` |

**Suggested rule:** refuse only the build's changed lines (hunks) in production files, or a list of production paths from project config. Files used by both agents (factories, test env, the dependency manifest) should be allowed once named in the plan's `support`.

- **CI files:** no evidence. Our CI runs no phpunit job, and phpunit finds new test files by directory. GUESS: a CI change by a tester should stay refused unless planned.
- **Snapshots:** none of our own besides the generated API docs above.
