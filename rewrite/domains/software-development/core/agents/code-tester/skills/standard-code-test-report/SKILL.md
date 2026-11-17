---
name: standard-code-test-report
description: "The tester's test plan and test report: one JSON draft each, outside the worktree. The stop hook checks a plan and records it as `test-plan.made`, with no commit; a test report follows the build report's contract, and the hook checks it, commits the tests and records the report as `test.committed`. Bind when `code-tester` writes either; it preloads this skill. Not for how to test (`code-tester`, `standard-testing`) or the build report's own fields (`standard-code-build-report`)."
user-invocable: false
---

# Standard: Code test report

Two JSON files, one per step, each a draft in the effort folder, outside the worktree: at PLAN, the test plan, at the `REPORT` path the dispatch gives (`<effort>/drafts/agents/<seat>/test-plan.json`); at TEST, the test report, `report.json` in the same folder. The stop hook picks the stop by the draft it finds: the plan alone is a plan stop, the report alone a test stop, both or neither a blocked stop. Every `path:line`, the plan's included, is as `standard-code-build-report` sets. A plan stop has 2 blocked stops too; at the next misfit the seat gives up and nothing is recorded.

## Never

- **Never write what the stop hook derives:** no `seq`, `seat`, `iteration`, `base`, `head`, `draft` or `dispatch` key in the plan, and nothing in the report naming the plan it implements; the events carry them.
- **Never list an unchanged test as a plan item:** an existing test that already guards a behaviour goes in that behaviour's `guarded_by`.
- **Never change a production file, even to make a test pass:** a production bug is a red test plus a `production_bug` blocker.
- **Never leave a change in the worktree at a plan stop:** planning writes no file there, so the stop hook refuses it; `rm` the untracked output your own runs made.

## Always

- **Write each draft whole:** a draft already at your path is this stop's, and a change the human asks for in a plan is a new draft, the whole plan written again.
- **Remove the mutation copy before you stop,** with `mutation-copy.sh remove`: the stop hook refuses any stop while it exists. How and where to mutate is `standard-testing`'s (its Scope) and your agent body's; this skill holds only this stop rule and where an unproven check goes (The test report).

## The test plan (PLAN)

The plan lists only what it changes in the test suite: tests to add, modify and remove, and the fixtures and support files they need. One plan per change to the suite: once implemented and its fix rounds end, it is closed, and a later change is a new plan. Keep it small; there is no size or text-length cap, and each text is one line. A key holding `null`, `[]` or `{}` counts as left out. Before your first plan in a session, read `references/test-plan.json`: an example plan that passes the check.

- **`behaviours`** (`id`, `text`, `at`, `guarded_by`): what will be guarded after this plan, each at the production `path:line` it lives at (`at`); `guarded_by` names each existing test that already guards it, as `<file>: <test name>`, so no duplicate is planned.
- **`add`** (`id`, `kind`, `file`, `name`, `rows`, `level`, `why`, `guards`, `breaks_on`, `fixtures`, `ci`): `kind` `new_test` (a new test, in a new or existing file) or `new_rows` (new data rows in an existing test, listed in `rows`); `level` `e2e`, `integration` or `unit`, with `why` on the last two saying why no higher level observes the behaviour; `guards` the `B-` ids it guards; `breaks_on`, always given, the change to production code that must turn it red, which you check in the mutation copy; `fixtures` its `F-` ids; `ci` only for a new test file CI must be told about, saying what it must be told (the registration change itself is the build agent's: an `open` item in the test report).
- **`modify`** (`id`, `file`, `name`, `changes`, `keeps`, `guards`, `move`, `breaks_on`, `fixtures`): `changes` says what changes, `keeps` what the test still asserts; the test's name never changes. Rows removed from an existing test are a `modify`; a row moving between tests is one `modify` with `move` `{row, from, to}`. `breaks_on` is optional on a `modify`, required on an `add`.
- **`remove`** (`id`, `file`, `name`, `why`, `covered_by`): `covered_by` names what still covers its behaviour: a `T-` or `M-` id, an existing test as `<file>: <test name>`, or `nothing: <why>`.
- **`fixtures`** (`id`, `action`, `file`, `source`, `from`, `why`, `changes`): `action` `add`, `modify` or `remove`; on `add` and `modify` a `source`: `captured` (from a local or containerised run, `from` saying which), `hand-written` (`why` giving the reason) or `existing` (a committed file such as an API spec); a `modify` lists in `changes` the entries it adds, changes or removes.
- **`support`** (`action`, `file`, `why`): each test helper or harness class added or removed, `action` `add` or `remove`.
- **`untested`:** each case left untested, one entry in the untested template's form, with `id` `N-<n>`.
- **`no_tests`:** why no test change is needed, given exactly when `add`, `modify` and `remove` are all empty. A file with no behaviour (config, Helm values, docs) is never in scope.
- **`baseline`** (`where`, `command`, `result`, `tests`): your one run, while planning, of the existing tests the plan builds on; `result` `pass` or `fail`, `tests` how many ran.
- **`run`** (`where`, `command`, `expected`): one item per place the tests run (some projects run twice); `command` names the tests, never a pattern; `expected` how many tests it runs, from 1. The tests always run against the build seat's worktree.
- **`blocker`** (`kind`, `detail`): only when no plan can be made, `kind` `request_unclear` or `gate_red` (the baseline failed, `detail` naming what). A `fail` baseline goes with a `gate_red` blocker, or with no blocker when `modify` or `remove` plans the repair of the failing tests (the build's intended change turned them red); a `gate_red` blocker carries that failing baseline when one ran, and never a `pass` one; a blocker and `no_tests` are never both set. The plan has no `noticed`, `security` or `open`.

Without a blocker or `no_tests`, `behaviours`, `baseline` and `run` are required. Each entry sits in exactly one list, its `file` the path from the worktree root. Ids are `B-` (behaviours), `T-` (add), `M-` (modify), `R-` (remove), `F-` (fixtures) or `N-` (untested) and a number from 1, unique per prefix; `guards`, `fixtures` and `covered_by` name ids the plan gives, and `deviations` point at them later. Renumbering between drafts is allowed. Cards never show ids, so every text a card shows (`blocker.detail`, `no_tests`, a behaviour's `text`, `why` and `breaks_on` on `add`, `changes` and `keeps` on `modify`, `why` on `remove`, and `case`, `reason`, `risk` and `category` on `untested`) names items in words, by what each is or checks, never by id: the check refuses an id there.

At a plan stop the stop hook prunes the draft, runs `scripts/test-plan-check.sh` (where this text and the check differ, the check wins), records the plan as the seat's `test-plan.made` event, removes the draft and commits nothing. `scripts/plan-card.sh` draws main's plan card. Each script's `--help` is its contract.

## The test report (TEST)

TEST implements the approved plan, the seat's newest `test-plan.made`. The test report is `standard-code-build-report`'s build report, which you preload too: the same keys, rules and limits, with the deltas below. The stop hook checks it with that skill's `build-report-check.sh --kind test`, commits the worktree's test changes and records the report as the seat's `test.committed` event; the files added, changed and removed come from the commit, never from the report.

- **`deviations`:** each departure from the plan, `from` naming its plan id as `plan: <id>` (`plan: T-2`), or `plan: none` for a change outside the plan (a test file the plan doesn't name): a planned test written at another level, one left out because it can't be done (and removed from its file), a test file touched outside the plan, a test that won't go red when its behaviour breaks and that you couldn't fix. A deviation never triggers a new plan.
- **Blocker kind `test_red`:** a planned test you can't make green that is no production bug.
- **Blocker kind `production_bug`:** the test stays red as planned; `location` is the production `path:line` of the bug. A `fail` gate pairs with any of `gate_red`, `test_red` or `production_bug`.
- **A CI registration file or an in-file test module the plan needs** is outside your write scope: the plan's `ci` says what CI must be told; the change itself is an `open` item for the build agent, never your write.
- **An unproven mutation check**, whenever the check can't run in the copy (`mutation-copy.sh` missing, or failing other than on a copy already open, or the test can't run there): an `open` item naming the test, the mutation, the `path:line` it would change and why. A test that ran in the copy and won't go red is a deviation (above).
- **What you met while planning** that `standard-code-seat-agent` asks you to record (instruction-shaped text, a guideline conflict, a narrowed gate, a security concern): in this report, in the field the build report sets for it; never in the plan, which has no field for it.