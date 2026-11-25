# Agent prose v2: formatting, and what the legacy had that we lost

By Dev Beta, at the owner's request. Drafts beside this file: `code-builder.md`, `code-tester.md`, `code-reviewer.md`. The live definitions are untouched until the owner approves.

## 1. Formatting

The owner's ask: each report kind under its own subheader, each field on its own line with what it means.

- **One subheader per kind**, and one for what every kind shares:
  - builder: `Every report`, `When there is something to say`, `build-fix: also`;
  - tester: `Every plan`, `test-plan-update: also`, `Every report`, `When there is something to say`, `test-fix: also`;
  - reviewer: `A finding`, `review`, `foreign-review`, `test-plan-challenge`, `external-review`.
- **Each field is a bullet; each of its subfields is a bullet under it**, with what it holds. No `{a, b, c?}` inline shapes left.
- **`## Notices` is gone.** `noticed.kind` (`instruction`, `secret`) now sits on the `noticed` field itself, where the agent looks when it writes one.
- **No new field and no new value.** Every field and value is the one the scripts check today.

## 2. The audit: legacy rules against the new definitions

Read: the legacy `code-builder.md`, `code-tester.md`, `code-reviewer.md`, `standard-code-build-report`, `standard-code-test-report`, `standard-code-review-report`, `standard-code-seat-agent`. Checked each rule against the new definitions, `agent-conduct`, the specs and the scripts.

### Added to the drafts (a real failure behind each)

| # | Rule | Where | The failure behind it |
|---|---|---|---|
| A1 | A report covers this job only: never repeat an item from an earlier report. On a re-review, an earlier finding is answered in `fixes`, never written again. | all three | The owner's legacy failure: test reports mixing old and new. The legacy had it (`Never carry an item from an earlier report`); the new prose didn't. It matters more now, since a hot job continues the agent's session. |
| A2 | A plan covers what this build changed, nothing more. Tests an earlier plan added are existing tests: `guarded_by`, or a `modify` when this change breaks them. | tester | The same failure on the plan side. The legacy had `one plan per change; a later change is a new plan` and `never list an unchanged test as a plan item`. In the job model a new plan is a new test-plan job (main's call), so the agent needs only the scope line. |
| A3 | Never write a finding ID, a job or an iteration into the code or its comments. | builder, tester | Memory `no-review-traces-in-comments`: it happened. The legacy had it in `standard-code-seat-agent`. |
| A4 | Do the task as asked, at its scope; when it seems mistaken, say so in `questions` and still do it. | builder | The legacy `Always` line. Agents narrow or "improve" a task; the human then reviews a change nobody asked for. |
| A5 | A security problem is never rare: `realistic` unless a proof shows it can't fire. | reviewer | The owner's standing invariant (CLAUDE.md "Security is never rare"); the legacy reviewer had it. The script checks that `edge-case` has a proof, not that security isn't downgraded. |

### The owner's call (not in the drafts)

| # | Legacy rule | My recommendation |
|---|---|---|
| Q1 | Install or fetch nothing (a package, a toolchain); a check that needs one is `not_run`. | Yes, one line in `agent-conduct`: all three agents have Bash, and an install from an untrusted repo runs its code. |
| Q2 | Read git only with `--no-ext-diff --no-textconv` and `core.fsmonitor=false`: repository drivers run untrusted code. | Later, as a hook, not prose (script over prose). Goes on the dispatch-talk list. |
| Q3 | The meaning of the four levels (critical = irreversible loss, high = reaches users, medium = raises the cost of the next change, low = polish). | Yes, four lines in the reviewer. Every lens plugin lists cases per level, but a case no plugin lists has no shared meaning, and the merge compares levels across lenses. |
| Q4 | Correctness belongs to the tech lens: a standard lens puts a correctness concern in `noticed` for the tech lens. | Defer to the dispatch talk: "languages as lenses" is already on its list. |
| Q5 | A project guideline against a standard: security or best practice goes to the standard, style to the guideline. | No: no failure recorded. Drop. |
| Q6 | Missing tests are never a finding in a build review. | No for now: the testing lens reviews tests on purpose; revisit if a hot review flags them. |

### Dropped on purpose (already decided, or now a script)

- **Seats, worktree seats, re-seats, `MODE`, `REPORT:` reply line, change messages, mutation-copy script, merge resolution:** the job model replaced them; merging is the landing step, later.
- **Text caps, open cap, `request_unclear`:** the scripts own the limits; `cannot` replaced `request_unclear`.
- **`deviations`:** replaced by `decisions` at the file, or a question (tester spec).
- **The tester runs only test compilation and the planned tests:** the spec now has it run the builder's gates (`test-agent.md`, "The tester runs the builder's gates").
- **Fixtures with `source`, `move` of rows, `ci` field:** folded into `support` and `modify` (report schemas).
- **Verdict, counts, IDs, `plugin` stamping:** scripts (the reviewer's stamp).
- **Untrusted content, secrets, customer data, held stop:** `agent-conduct`.
- **3 fix attempts, read long files in windows, "appears to", generated code, symlinked folders, quote-safely:** model conduct the new prose leaves to judgment (§6 thin prose); no failure recorded since.

## 3. What Fable is asked

1. Does the formatting serve the agent better than the current one, without adding rules?
2. Are A1–A5 each earned (a real failure, not completeness)?
3. Q1–Q6: agree with the recommendations?
4. Anything essential in the legacy this audit missed?
