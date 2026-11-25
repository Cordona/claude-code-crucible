# The test agent's slice: Fable's check (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `test-agent-fable-brief.md`. Talking only; the owner's go is the only go.

**What I read:** the brief, `test-agent.md`, `build-agent.md`, `report-schemas.md` sections 0, 3, 4 and 9, `decisions.md`, the built `agent-submission`, `agent-jobs` and `code-builder` in new-rewrite, and the old rewrite's tester write scope and plan check. I ran nothing.

## Verdict

**The slice is sound and follows the builder's design.** Of the owner's four points I approve three, and would answer the first another way. Of the three open points I agree with one, would drop one, and the third needs a rewrite because its two rules contradict each other.

**Three things to settle before it is built:**

1. **A test that finds a production bug must be committed.** The slice says "no commit". The built hook commits whenever the tree changed, and here the red test is the proof.
2. **Where the build report's rules live for the tester.** The test report is "the build report with three differences", and those rules sit in `code-builder`'s lib today.
3. **What a tester may change** (open point 3).

## 1. The owner's four points

| # | Point | My view |
|---|---|---|
| 1 | `level` on `modify`, and a table per action | **Table: yes. `level` on `modify`: no.** |
| 2 | Say the test report has every build-report field | **Yes.** |
| 3 | A folder per report kind | **Yes, as a reading aid,** named after the job's kind. |
| 4 | The rework as its own job kind | **Yes.** |

**Point 1.**
- **The table per action is the real fix.** The owner read the different fields as an oversight because the spec shows them only in an example. A table of each action's required and optional fields ends that.
- **`level` on `modify` has no reader.** On `add` a rule reads it: a `unit` or `integration` test must say why it can't be end to end. A modified test's level was chosen long ago; nothing asks why. The card would be its only reader, and nothing could check what the agent wrote. So have the card count added tests by level, and modified and removed tests by action. The old rewrite's plan had no level on a modify either.
- **The table will show two gaps to close:**
  - `guards` isn't required anywhere in the rules, so a test may guard nothing. The old plan required it on `add` and `modify`;
  - `breaks_on` on `modify` is in the example, but no rule says whether it is required.

**Point 2.** Say it in one sentence, and show one fuller example. The sentence should also say what the check's unknown-key line lists, since that line is what the agent sees.

**Point 3.**
- **It passes on one reader, the human** looking into an effort's folder, as the commit trailers did. No script may take the kind from the path; the kind's home is the job.
- **Name the folder after the job's kind, exactly,** not after the event. Then there is no table to keep: `reports/<kind>/<job seq>.json`.
- **It is cheap now.** The path is already whatever the job names; only one pattern in `events-view.sh` fixes its form. Do it before a second agent is built.

**Point 4.**
- **It follows two rules we already have:** one event type per different next step, and one submission file per kind. Today one kind would have to give two event types, which is the special case the per-kind files were meant to remove. `fix` beside `build` is the precedent.
- **Say what the job carries.** A rework comes from two places: the challenge, or the human's changes at the gate. So a `test-plan-update` job carries challenges, the human's words, or both. With no challenges there is nothing to answer.
- **`test-plan-challenge` for the challenger:** agreed, in the reviewer's slice.

## 2. The three open points (section 10)

**1. `plan` in `test.submitted`: I'd drop it.**
- The plan a test job writes from is a fact of its dispatch. Its home is `job.dispatched`, and the event already names the job.
- It isn't like the iteration. The iteration is on every event and read by the cards, the cap and the timeline. The plan link has one reader, the review of the tests, which reads the job anyway.
- A tests-side fix needs the plan too (its write scope comes from it) and carries no `plan`. So readers must go through the job in any case.
- Every submission event then keeps one shape. `job-of.sh` prints the plan for whoever asks.
- **One gap this shows:** the slice doesn't say how a tests-side fix job knows its plan. Its dispatch should name it, as the test job's does.

**2. The challenge belongs to the reviewer's slice: agreed.**

**3. What a tester may change: the two rules contradict each other.**
- The slice says anything the plan doesn't name is production, and refused outright.
- It also has a second rule for a file the plan doesn't name: "undo it, or say why in decisions".
- Both can't hold: by the first, `tests/Upload/OtherTest.php` is production.

**What I'd do, with no list of test folders or file names** (the old rewrite judged by path, with a list per ecosystem that kept growing):

| A changed file is | What happens |
|---|---|
| named in the approved plan | allowed |
| one the build under test changed | refused, with the `production_bug` line. This is a fact from the build's commit, not a guess |
| anything else | refused, unless a `decisions` entry points at it. The card then shows it as a departure from the plan |

That keeps the hard rule where a script knows for a fact, and gives a real project its way out: a new helper, a test config, a snapshot the run wrote, a test dependency in the build file. The workers can say whether these are the real cases; I wouldn't add more than this before one of them bites.

## 3. Drift from the builder's design and from the old rules

**To settle before building:**

1. **A blocked test job still commits.** Section 9, case 6 says a test that finds a production bug ends "blocked, with no commit". The built rule is simpler: nothing is committed only when the tree didn't change. Keep that one rule. The failing test is what the builder's fix must turn green, and the next job starts from a clean tree, so it has to be in a commit. Working commits never land, so a red one harms nothing.
2. **The shared report rules need a neutral home.** The test report and the tests-side fix use the build and fix report rules, which are in `code-builder/scripts/lib/`. The tester shouldn't copy them, and shouldn't depend on the builder. Move what both use (text, locations, gates, known failures, blockers, the fix answers) to the component that hands in any agent's work, and let each agent's check add its own. The event rules already reach `agent-jobs`' lib this way.
3. **The `testing` standard rule names an agent inside the jobs.** "The dispatch rule for a `code-tester` job refuses one without it" would put an agent's name into `job.dispatched`'s rule, when the submission hook was built to know no agent. The rule is the owner's and stays. Where it lives is a dispatch question: I'd have the agent's own component say what its jobs need. Case 9 builds part of the dispatch, so I'd leave it out of this slice and take it to the dispatch talk.

**Smaller:**

- **`test_red` beside `gate_red`.** I passed it in draft 2 and now doubt it. `production_bug` has a different next step (a fix for the builder). `test_red` and `gate_red` both mean "a check fails and I couldn't fix it"; name what treats them differently, or fold them.
- **"The side comes from the job."** The side already follows from which agent's component checks the report. If the job also has a `side` field, that is a second home.
- **`decisions[].why` may name `plan T-1`,** while the plan refuses internal IDs in text a human reads. No script reads that mention. Say it in words, as everywhere else.
- **The rework's answers use `challenge` as the key,** the fix's use `id`. One name.
- **Carried over from the schemas, missing here:** a plan reworked after the human's changes isn't challenged again by itself; main may offer it.
- **The commit subject** gains `crucible(test)`. `git-commit`'s help should say so; the help is the contract.

**Checked and found right:**
- the events are slim, with the draft-3 extracts (`counts`, `baseline`, `blocked`) gone;
- the iteration is inherited from the build at dispatch, and the fix round as for the builder;
- a plan job changes nothing in the tree and makes no commit;
- the approval stays the gate's own answer, and a plan changed after approval refuses the test job's dispatch;
- the readiness check and the missing-file fault are reused as the owner decided.

## 4. Order I'd take

1. The three points of the verdict, in the spec.
2. The report folders and the shared report rules in the built builder, with its proof rerun.
3. Then the tester's build, and one live check with a real tester.
