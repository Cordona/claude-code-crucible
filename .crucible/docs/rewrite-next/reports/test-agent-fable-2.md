# The test agent, version 2: the workers' answers judged (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `test-agent-fable-2-brief.md`. Talking only; the owner's go is the only go.

**What I read:** the brief, the five workers' answers, and `test-agent.md` version 2 (sections 2, 4, 5, 8 to 11). I ran nothing.

## Verdict

**The workers are right about section 5, and the rule they refute is the one I proposed.** "A file the build changed is refused" fails on real work in all five repos. The repair is smaller than a path class: the approved plan is the scope, and a planned file always wins.

**Of the rest, five things change the spec and none of them is a new concept.** Everything else is already answered by the design, is text, or belongs to another slice.

| Changes the spec | How |
|---|---|
| What a tester may change | the plan wins; the rule below |
| `production_bug` anywhere | drop the "file the build changed" limit on `at` |
| A removed behaviour | restore `covered_by: "nothing: <why>"` from the schemas |
| Many tests, one change | `names`, a list, on `modify` and `remove` |
| A pure repair | `guards` optional on `modify` |
| A folder of goldens | `support[].file` may name a folder |
| Breaks tried and caught | one more gate value, no per-test list |
| The examples | no unfiltered full-suite run |

## 1. What a tester may change (themes 1, and question 2)

**Not a path class.** A list of test-support paths has to live somewhere. In the framework it is one ecosystem's layout (`database/factories` is Laravel's) and it grows, which is what the old rewrite's list did. In the project it is a new configuration file that every project must write before a tester works.

**The plan already is that list, written per change and approved by the human.** So:

| A changed file is | What happens |
|---|---|
| named in the approved plan, in `tests` or `support` | **allowed, whatever else is true of it** |
| not in the plan, and the build under test changed it | refused |
| not in the plan, anything else | refused unless a `decisions` entry points at it; shown on the card as a departure |

**How the workers' cases come out:**

| Case | Outcome |
|---|---|
| A factory or seeder, also when the build made it | a `support` entry: allowed |
| A test file the build touched | planned: allowed |
| The CI test registry (`suite-N.txt`) | a `support` entry. The planner names it because the project requires it; no derived companion |
| `phpunit.xml`, `.env.testing`, a base `TestCase` | planned, or a departure on the card |
| A dev dependency in `composer.json` | allowed when planned, which is what Epsilon asks: the human approved it at the gate. Unplanned and the build touched the file: refused |
| A seam on a production file (`use HasFactory`) | a `support` entry the challenger and the human see, or a `cannot` blocker handing it to the builder. No `seam` kind |
| Files a test run writes | the commit follows the project's ignore rules, as the builder's does |

**Two things I'd leave as they are, and say why:**
- **CI files and dependencies through a `decisions` entry.** Three workers find that too loose. No script can tell `.gitlab-ci.yml` from a helper without the path list. What protects here is already in the design: the departure is on the card, and a working commit never lands without the human. A project that never wants them touched says so in its own instructions to the agent.
- **The refusal line for a build file** shouldn't say `production_bug` any more. A factory isn't a bug. Say: name it in the plan, or report what you need.

**A production bug anywhere.** Three workers hit an old bug in a file the build didn't change. The limit on `at` was part of my rule and goes with it: `at` is any location outside the plan's own files, and `@<where>:path` already exists for another repo. No `relates_to` and no "pre-existing" mark: the human decides at the card whether it is fixed now or later.

## 2. The plan's fields (themes 2 to 5, 9, 10)

| Theme | My view |
|---|---|
| **`remove`, the behaviour is gone** (4) | **Already designed, lost in this slice.** `report-schemas.md` allows `covered_by` to be a `T-` ID, a `<file>: <test>`, or `nothing: <why>`. Carry it over. No `gone` or `why` field. |
| **Many repairs, one change** (78, 45, and 65 removals) | **Yes.** On `modify` and `remove`, `name` becomes `names`, one or more tests in one file sharing the entry's fields. Tests whose `keeps` differs get their own entry. The card counts names. |
| **A pure repair guards nothing** (1) | **Make `guards` optional on `modify`.** I asked for it to be required and that was too much: a repaired test guards no behaviour of this change, and `keeps` is its guard. Required on `add`. No `repairs` field; `changes` says why it broke. |
| **A row or test that moves, a rename, a merge** | **Text.** `changes` says where it went, in words, and the receiving test has its own entry. A merge is a `modify` of the one kept and a `remove` of the other, covered by the first. No `moves_to`, `new_name` or `replaces`. |
| **An existing shared file** (`changes`, `keeps`, `affects`, `reaches`, `from`) | **Text in `what`.** The challenger is the reader, and it reads text. No script would treat a count of callers differently. Say in the field's description what `what` must tell for an existing file: what changes, what stays, how a golden is made. |
| **A folder of regenerated goldens** | **Yes:** `support[].file` may name a folder. A script reads it for the scope, so it is a real shape. No globs. |
| **`untested.category`** | **Stays dropped.** Nothing here reads it; the worker's waiver rule is the old plan's. |
| **Test-only secrets** | **Answered.** `what` says it is generated and not real. Nothing holds a stop for it, because there is no scan. |

## 3. The test report (themes 6, 7, 8)

- **That `breaks_on` was checked** (2). A real practice, and the old rewrite required it. A per-test list `{test, broke, red}` is the agent's word repeated per test, and nothing could check it. Use what exists: one more gate value for it, with the usual results. `pass` with a note ("34 breaks, all caught"), or `not_run` with why. The card shows it and the reviewer of the tests reads it. Whether a test report must carry that gate is the owner's call.
- **Whether `keeps` held, per repaired test.** Answered: a departure from the plan is a `decisions` entry, and silence means it held. Checking it against the commit is the test reviewer's job.
- **Which suites were re-run** after a shared helper changed. Answered: a `narrowed` gate's note says what ran.
- **The baseline:**
  - **known flaky failures:** known failures come from the job, never from the agent. An unknown red baseline goes to the human as a blocker, and the human's "that one is known" reaches the next job. How it reaches it is the dispatch's;
  - **570 failures:** a `failing` line may name a file or a group with its count. No count field;
  - **can't run locally:** `not_run` with a note is already allowed, and the plan gate shows it.
- **The `run` examples:** fix them. Whether a project requires a filter is the project's rule, not the framework's.

## 4. What belongs to another slice (question 3)

| Slice | What |
|---|---|
| **The landing step** | a committed red test blocks any push until the fix turns it green; a new dependency or a CI change is seen by the human before it lands |
| **The dispatch** | the human's "known failure" reaching later jobs; a project's own never-touch paths and filter-only rule reaching the agent |
| **The reviewer's** | whether `keeps` held; whether a golden only mirrors the code; a shared helper's reach; judging the breaks that were tried |

## 5. A note on the round

Twelve fields were proposed and I'd add one (`names`) and widen two (`guards`, a folder in `support`). The workers' cases are all real. Most were answered by the plan being the human's approved scope, which section 5 had made weaker than it is.
