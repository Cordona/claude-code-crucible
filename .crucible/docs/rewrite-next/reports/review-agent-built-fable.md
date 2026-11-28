# The reviewer slice as built: Fable's design review (2026-11-24)

By Crucible Fable Reviwer, for the owner. Design only. Talking only; the owner's go is the only go.

**What I read:** all of `agents/code-reviewer/`, the new plumbing (`report-stamp.sh`, `stop-lock.sh`, the lock's use in the wrapper), `job.dispatched.jq`, `iteration.jq`, the submission check in `jobs.jq`, and the builder's and tester's common rules for comparison.

**Not done:** I reran none of the proofs and judged no implementation detail.

## Verdict

**The design is sound, and both of the owner's worries hold up.**

- **Plumbing-only sharing: yes.** Nothing in `agent-submission` or `agent-jobs` names an agent or one of its kinds. The stamp step mirrors the check step: it runs the rules the agent's own file names.
- **No rule without a failure: yes.** The four rules I asked to take out are out, and the builder's four departures from the spec all made it smaller.

**Three things I'd change,** none of them urgent:

| # | Finding | Weight |
|---|---|---|
| 1 | The job's start rule holds the agents' own words | medium |
| 2 | The form of a location is written three times, and already differs | medium |
| 3 | One facts script serves the checks and the stamps, and runs under the lock | low |

## 1. The job's start rule holds the agents' words

`job.dispatched.jq` checks only shapes now, as agreed. Two of those shapes still list an agent's own vocabulary:

- `earlier[].status` must be `done`, `partly` or `declined`: the fixers' words;
- `challenges[].ask` must be `add`, `change`, `remove` or `prove`: the challenger's words.

If a fixer's word changes, `agent-jobs` changes with it. That is one agent's content in the shared job model, which is the coupling the owner named.

**What I'd do:** `agent-jobs` checks that these are lists of entries with an ID. The words are checked by the agent whose rules read them, and the reviewer's rules already do that for the statuses.

The list of fields a job may carry has grown to twenty. That stays a question for the dispatch talk.

## 2. The form of a location, three times

The copies the owner chose are there as chosen: the builder's and the tester's common rules are the same 156 lines but for two. That is the agreed price.

**One part has already drifted, and it is the part every reader shares:**

| Agent | What its rules accept as a location |
|---|---|
| builder, tester | `path:N`, and `@<where>:path:N` |
| reviewer | also a bare `path`, `path:N-M`, `-path:N`, and a list |

The schemas say every report uses the same forms. A builder can't cite a range today.

**This is the one rule I'd move into the plumbing.** It already owns the form: `report-check.sh` reads every `at`, looks the file up and counts its lines, before any agent's rule runs. Whether a location is well formed, names a file and is within it are facts the plumbing has. It could print those lines itself, and each agent's copy of that rule would go.

It fits the contract we stated: any `at` in a report is a location. It is the owner's call, since it is the plumbing saying something about a report.

## 3. One facts script, run twice

`reviewer-facts.sh` gathers eight facts for four kinds and is run for the check, then again for the stamp. It has no branch per kind, which is what I asked to watch. Two things follow from it serving both steps:

- every kind pays for every fact: a plan challenge also gets the diff and the thread list;
- the second run is inside the stop lock, where another agent's stop is waiting. Only the IDs and keys taken so far are needed there.

**What I'd do:** let the `stamps` entry name its own small facts script (the IDs and the keys). The lock is then held for less, and each script has one reader.

## 4. The builder's four departures from the spec

| # | Choice | My view |
|---|---|---|
| 1 | The tree check is the reviewer's own rule; the plumbing only says whether the tree changed | **Right.** The plumbing gives the fact, the agent decides what it means |
| 2 | A challenge's target is checked by its file only | **Right.** No failure stands behind checking the helper inside it |
| 3 | The cover rule applies only when the job has a base and a head | **Right for now.** A review job without them has no cover check and nothing says so. The dispatch must require them for a review |
| 4 | Two repair lines in its own words | Not judged |

## 5. Smaller

- **A missing lens is guessed.** The stamps fall back to `REVIEW-NN` when the job names no lens, and to `human` when a thread's source is unknown. A guess reads as an answer. I'd have the stamp fail and tell the human, as for an install fault.
- **The event rules are eleven files with the same line.** That is the core's rule of one file per type, and it is what shows who owns which event. Fine.
- **The lock is right as built:** its own folder, not the core's lock, a dead owner's lock is broken, and when it can't be taken the human is told and nothing is handed in.

## 6. Order I'd take

1. The owner's word on finding 2.
2. Findings 1 and 3 with the next change to those files.
3. The guessed lens, before a real triage runs.
