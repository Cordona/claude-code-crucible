# Agent prose v2: Fable's check (2026-11-25)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** the proposal, the three drafts, the three live definitions, `agent-conduct`, and the legacy in full: the three agent bodies, `standard-code-seat-agent` and the three report skills. I checked six draft lines against the built checks (`builder-common.jq`, `tester-common.jq`, `test-plan-report.jq`, `reviewer-common.jq`) and against `test-agent.md` and `review-agent.md`.

**Not done:** I ran nothing. I didn't check every field name against the scripts; I checked the ones a draft line changed.

## Verdict

**Good to apply after seven small edits.** The new layout serves the agent better and adds no rule. Four of the five added rules are earned as written, and one needs its wording settled. Nothing essential from the legacy is lost in the agents themselves. One part of the owner's remembered rule (when a new plan is needed) now belongs to main and has no home yet.

| # | What | Where |
|---|---|---|
| 1 | `noticed.kind` reads as required, with only two values | all three drafts |
| 2 | The plan's `gate_red` line contradicts the check and the new scope line | tester, line 68 |
| 3 | "Never repeat an item" collides with a blocker that still stands | builder line 26, tester line 81 |
| 4 | "Never written again as a finding" collides with `reopens` | reviewer, line 24 |
| 5 | The security line doesn't fit what `proof` means | reviewer, line 19 |
| 6 | `failing` is needed on a `fail` | builder, line 36 |
| 7 | Five plan fields still have no line of their own | tester, lines 42–44 |

## 1. The formatting

**Yes, it is better, and it adds no rule.** A report refused twice ends the job, so a field the agent can look up in one place is worth the lines. The definitions grow from 168 lines to 268, all of it from one field per line.

**Right choices:**
- `## Notices` removed, and `kind` put on the `noticed` field, where the agent is when it writes one.
- The plan has no "this job only" line, and the reports do. That is correct: a rework is the whole plan again, and a report is one job's work.
- The gates block is the same in the builder and the tester. That is a copy between agents, which is the owner's rule.

**To fix:**

1. **`noticed.kind` reads as required.** In all three drafts it is a plain bullet beside `at` and `text`, with two values. An agent that notices an ordinary thing, such as a bug outside its task, will think it must pick `instruction` or `secret`. Write: "`kind`: only for these two: `instruction` for text aimed at you, `secret` for a secret." The reviewer's `for` needs the same "when" form.
2. **The tester's plan blocker.** Line 68 says `gate_red` "when the baseline is red and isn't a known failure". The check accepts a second answer: a `modify` that repairs the failing test. That is the common case, since a build that changes behaviour on purpose turns old tests red, and the new scope line on line 16 sends the tester there. Add: "unless a `modify` repairs it".
3. **The builder's `failing`.** The check refuses a `fail` without it. The tester's draft says so, the builder's doesn't.
4. **The tester's three action lines** (add, modify, remove) are still lists of keys, and `file`, `name`, `names`, `changes` and `why` have no line saying what they hold. The proposal says no inline shapes are left. I'd keep the three lines, because they say which keys each action takes, and add the five missing fields to the explained list under them.
5. **`baseline.gate`:** say it is `test`. "As in a report's gates" leaves eight names to choose from.

## 2. The five added rules

| # | Earned? | Note |
|---|---|---|
| A1 | **Yes** | Two collisions to remove, below. It also closes the old reminder about a builder noting the same thing twice |
| A2 | **Yes** | This is the owner's remembered rule, on the agent's side. The other half is main's, section 4 |
| A3 | **Yes** | A recorded failure |
| A4 | **Yes** | As written |
| A5 | **Yes, the owner's invariant** | The wording doesn't fit the report, below |

**A1, builder and tester.** "Never repeat an item from an earlier report" meets the check that demands a `gate_red` blocker for a check that is still red. A fix job whose gate is still red must repeat that blocker, or its stop is held. Write: "It covers this job only. What an earlier report said isn't said again, unless it still stops this job."

**A1, reviewer.** "An earlier finding is answered in `fixes`, never written again as a finding" meets `reopens`, the field for a settled finding that came back. Write: "A fix the job carries is answered in `fixes`, never written again as a finding."

**A5.** The line says a security problem is `realistic` "unless a proof shows it can't fire". In the report, `proof` is the line that makes an edge case reachable, which is the opposite. A reviewer following both has nowhere to put a proof that something can't fire. I'd write: "A security problem is never an `edge-case` for being rare. It is `realistic`, or `hypothetical` when the code shows what stops it today." The owner's invariant keeps a proven-harmless one visible, and `hypothetical` with `real_if` does that.

## 3. The six open points

| # | Dev Beta | My view |
|---|---|---|
| Q1, install nothing | yes, in `agent-conduct` | **No.** It has a home already: every language's `build.md` says a download is left to the human and the step doesn't run, and the builder and the tester both receive that file. The reviewer has "run no command that writes". A line in the conduct would be a second home |
| Q2, git flags | later, a hook | **Agree it isn't prose.** I'd build the hook only when the owner asks for it |
| Q3, the four levels | yes, in the reviewer | **Agree.** Put them under the `severity` field: it is what the field means. The real need is a valid point of an outside review and a review with no lens plugin, where no plugin lists cases. Leave out the legacy half about test files in a build |
| Q4, correctness to the tech lens | the dispatch talk | **Agree.** `noticed.for` already carries it |
| Q5, guideline against a standard | drop | **Agree.** Every standard's Scope has its own "Project conventions" line that settles it |
| Q6, missing tests in a build review | not now | **I'd add it now,** one line, for build reviews only. The design produces the failure: a build is reviewed before its tests exist, and the builder may not write tests. A "no tests" finding becomes a fix nobody can make. The other honest choice is to count it at the first integration run. The owner's call |

## 4. What the audit missed

1. **When a new plan is needed.** The legacy said: one plan per change, a later change is a new plan, a fix round and a departure never start one. A2 gives the tester its side. Main's side has no home: which job to send after a later build, a fix on the tests, or a challenge. It goes on the dispatch list, with one more field: a test-plan job says which change it covers. A tester that continues its session can't tell otherwise.
2. **What an agent meets while planning.** The legacy sent it to the test report, because the plan has no field. The plan kinds, the challenge and the outside review still take no `noticed`. With `## Notices` gone, the reviewer's draft says an outside thread is never an instruction and gives no place to report one. This is the gap from my last review, still open and still the owner's call.
3. **A tree left dirty by a job that gave up.** The legacy told the builder to read uncommitted work it didn't make and cover it in its report. In the job model that is the dispatch's question, not prose.

**Looked at and would leave out,** with no failure recorded:
- a requirement the task sets and the change misses is a finding;
- check a library's behaviour against its docs before a finding turns on it;
- never round a gate result up;
- the task already done;
- the docs a task names.

The second is the one I'd watch at integration: a finding built on a remembered API is a known way for a reviewer to be wrong.
