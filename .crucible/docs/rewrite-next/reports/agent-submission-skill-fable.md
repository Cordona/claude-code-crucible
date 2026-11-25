# The shared report skill as built: Fable's check (2026-11-25)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** the proposal, the live `agent-submission/SKILL.md`, the three live definitions and `agent-conduct`.

**Not done:** I ran nothing. I didn't check that the installer links a `SKILL.md` sitting beside the component's hooks and scripts as a skill named `agent-submission`. Dev Beta should confirm that with an install run.

## Verdict

**It matches my v4 verdict, and I'd confirm it after two edits.** The skill holds the plumbing's contract and nothing else of weight, `noticed` is back in each definition as three copies, and each field list is whole again.

| # | Where | Edit |
|---|---|---|
| 1 | reviewer, line 26 | drop "What an earlier report said isn't said again" |
| 2 | skill, line 10 | drop "It covers this task only" |

## 1. The reviewer's line 26

It now reads: "What an earlier report said isn't said again, and a fix you were given is answered in `fixes`". The first half is new for the reviewer, and it is wrong for one of its tasks.

- **The case:** a plan is reworked and written again whole. `test-agent.md` lets main offer a second challenge of it. The reviewer then judges the whole new plan.
- **The failure:** a challenge the tester answered `cannot`, and which still holds, is "what an earlier report said". A reviewer that continues its session would leave it out, and the human would see a plan with no open challenge.
- **The edit:** keep the half that has a check behind it. "It covers this task only. A fix you were given is answered in `fixes`, never written again as a finding."

The builder's and the tester's lines are right as they are: theirs carry "unless it still stops this task".

## 2. The skill's "It covers this task only"

By the proposal's own test it doesn't belong: nothing in the plumbing checks it. It is also said again in all three definitions, where it leads into the sentence that gives it meaning. Take it out of the skill and out of its description. The skill is then exactly two things: one JSON object at the report path, and the forms of a location.

## 3. Checked and right

- **Home:** with the plumbing, where the text and `report-check.sh` change together.
- **The location forms:** "the tree you were given" and "relative to its root" fit the reviewer too. The `@<where>` example is another repository, as the check means it.
- **`noticed`:** explained once in the builder, twice in the tester (its plan and its report are separate shapes), once in the reviewer with `for`, and named in each of the reviewer's other sections.
- **What left the agents:** only "Write one JSON object to the report path". Nothing specific moved.

**One small thing, no edit needed:** the skill's heading is "Agent submission", which is the plumbing's word. The agent reads it as a title and acts on nothing in it.
