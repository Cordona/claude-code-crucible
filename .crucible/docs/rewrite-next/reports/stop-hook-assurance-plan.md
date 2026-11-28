# Assurance plan, v2: every report an agent writes is checked, the failure reaches the agent, and every outcome is an event

By Dev Beta, for the owner. Version 2 applies Fable's verdict (`stop-hook-assurance-fable.md`). Fable agrees to it as the plan to put to the owner (`stop-hook-assurance-fable-2.md`); its three points are folded in below. Context: `stop-hook-guarantees.md`. The owner dropped G2 (jq missing) as hypothetical.

## What the owner is assured of

For every report kind, without main's reasoning or any prose rule:
- **A0, the job is found:** an agent of a job-taking type that stops with no job found is told to the human. It never passes in silence.
- **A1, the check:** a bad report (not one JSON object, a bad location, missing or misplaced, a coverage miss such as an unaddressed finding, a tree change it may not make) is refused by a script.
- **A2, delivery:** the repair lines reach the same agent automatically, through Claude Code's SubagentStop block, for background and foreground agents alike.
- **A3, recovery:** the agent repairs and stops again, and is accepted.
- **A4, tracking:** every outcome is an event, by the time main ends its turn, or, for a dead session, before anything else is done with that tree or effort: submitted, refused, gave up, fault (naming the failed step), or never stopped. Its honest limit: when the event log itself can't be written, the human's message is the record.

All of it is proven with real Claude Code sub-agents in sandbox sessions, scored by scripts that read only events, report files and git.

## The kinds (10)

`build`, `build-fix`, `test-plan`, `test-plan-update`, `test`, `test-fix`, `review` (cold, hot and re-review), `test-plan-challenge`, `external-review`, `foreign-review`.

## Step 1: probes of Claude Code itself (sandbox, stand-ins)

A kit kept in `evidence/stop-hook-probe/`, rerun after each Claude Code update. Each result records the Claude Code version.

| Probe | Question |
|---|---|
| P1 | Does a block's reason reach a background agent twice in a row? Is there a cap on blocks? |
| P2 | For the turn limit, TaskStop, an API error, the human interrupting, and main ending while the agent runs: which hooks fire at all, and with what `agent_id`? |
| P3 | Does a hot agent resumed with SendMessage for a new job run the hook again, for that job? |
| P4 | Do parallel agents each get only their own block and reason? |
| P5 | Is `job.assigned` in the log before the agent's stop, for background and foreground agents? |
| P6 | What is the hook's time limit? Twelve parallel stops queue on the stop lock (up to 60 s) and then commit: does any get killed, and does a killed hook leave a trace? |
| P7 | An agent refused once that can't continue (turn limit, context spent): what fires? |
| P8 | Does a block reach a foreground agent too? |

The results decide the design of A0 and of `no-stop` in step 2.

## Step 2: close the design gaps (scripts, with scripted proofs)

| Gap | Change |
|---|---|
| A0: no job found means a silent pass | The hook gets the agent's type. When that type has a `submissions/` folder and no job is found, the human is told. |
| A refusal leaves only a counter file | Each refusal writes `job.refused` {job, iteration, fix_round?, agent, try, lines}. The refused file isn't named, since it's overwritten and never pinned. The tries are counted from these events, and `stops/<seq>.held` is dropped, so the fact has one record. |
| A refusal event that can't be written | Today "could not be counted" lets a bad report through. Now the stop is still held, and the human is told. |
| A fault writes no event | Split by when it happens: before acceptance, `job.ended` {reason: fault, step, fault}; after acceptance (stamp, pin, working commit, event, the stop lock held too long), `job.ended` {reason: fault, step, …}, naming the step. Main can then tell "start again" from "finish handing in", and the accepted report is never thrown away. |
| An agent that never stops, or stops refused and can't continue | `job.ended` {reason: no-stop}. Its writer is decided by P2, P5 and P7. |
| The exit trap exits 0 on any error, so a bug is a silent pass | The hook notes the outcome it reached. An exit with no outcome noted is a fault told to the human. **Owner's call.** |
| Repair lines | Every distinct repair line in every rules module has a `run.sh` case. |

Fable reviews the event shapes before they're built. **The open question for that review:** after a fault after acceptance, either the job ends and finishing the hand-in is a new event referring to it, or the job doesn't end and the event says it waits to be handed in. Either way a job never has two endings in the log.

## Step 3: the mechanism matrix (sandbox, steered stand-ins, all 10 kinds)

**What the human is told is scored too:** in the sandbox the hook is registered through a small wrapper that saves what the hook prints, one file per stop. The scorer reads those files. The hook is unchanged, and no transcript is read.

**Control run first:** the matrix is run once with the hook not installed, and the scorer must go red on every scenario. Otherwise green proves nothing.

| Scenario | Kinds | Expected |
|---|---|---|
| S1 accepted first time | all; review as cold and as hot | submission event; pinned; committed when the kind commits |
| S2 refused on the kind's own rule (below), repaired | all | `job.refused` try 1, then the submission |
| S3 report written to the wrong path, then moved | all | `job.refused` naming the right path, then the submission |
| S4 refused twice | all; review as hot too | `job.refused` ×2, `job.ended` gave-up, the human told; nothing pinned or committed |
| S5a install fault before acceptance (a rules file removed) | one per agent | `job.ended` fault, step check |
| S5b fault after acceptance (a scratch repo whose working commit fails) | build, test | `job.stalled` step commit; the report pinned and kept; then `recover-submission.sh --finish` gives the submission; on one kind `--give-up` gives `job.ended` fault |
| S6 a bad location | all | `job.refused`, then accepted |
| S7 the tree changed where it may not be (a planner or reviewer edits; a test job edits a file outside its plan) | test-plan, review, test | `job.refused` "undo …", then accepted |
| S8 not one JSON object (a trailing comma, a code fence) | all | `job.refused` "write your report as one JSON object to …", then accepted |
| S9 twelve reviewers refused at once | review | twelve `job.refused`, each with its own lines, then twelve submissions; unique IDs |
| S10 no job found for a job-taking agent | one per agent | the human told (A0) |
| S12 the no-stop writer: an agent killed by TaskStop mid-job; a running agent at the same turn end; a hot agent assigned at PreToolUse(SendMessage) while it runs | one per agent type | `job.ended` no-stop for the killed one only; the others untouched |
| S13 the Bash hook: a job agent tries `run_in_background` | one | denied, runs in the foreground, then the submission |
| S11 a parked stop: a command outlives its timeout and the agent ends its turn waiting | one per agent | `job.refused` try 1 "write your report", then the submission |

The kind-specific rule for S2:

| Kind | Rule it breaks first |
|---|---|
| build | a summary too long |
| build-fix, test-fix | a chosen finding left out of `fixes` |
| test-plan | an ID in human text |
| test-plan-update | a challenge left unanswered |
| test | the mutation gate left out |
| review | an edge-case finding without proof |
| review (re-review) | an earlier fix without a status |
| test-plan-challenge | a challenge naming an unknown target |
| external-review | a thread left unjudged |
| foreign-review | an edge-case finding without proof |

## Step 4: the real definitions (sandbox, real agents)

- The real `code-builder`, `code-tester` and `code-reviewer`, with their skills and plugins, on the model the framework will really use. The haiku stand-ins don't carry over.
- **Three runs per kind** on small real tasks, with tasks shaped to make natural mistakes likely. For example, a fix with three findings, one hard to place, or an outside review with a point hidden in a reply.
- **Counted per kind:**
  - accepted at the first stop;
  - repaired after one refusal;
  - gave up.

  **The bar: zero gave up.**

## Step 5: exit criteria

- Steps 1 to 4 green, each scored by a script.
- **A probe is done** when its answer is recorded with the Claude Code version. An answer we don't like isn't a failed probe. If an answer breaks something we rely on, the step 2 design changes, and the owner is told before step 2 starts.
- An audit script over every run's log finds:
  - every job ended or submitted;
  - every pinned report matching its hash;
  - every working commit with its event;
  - every refusal followed by a submission or an end;
  - no job with more than two refusals.
- Fable reviews the event shapes (step 2) and the matrix's coverage before step 3.
- The owner's go before each step.

## Left out, on purpose

- Not counting a first missing-report refusal (G6): the dispatch's job check handles a missing path.
- Any machinery that watches agents: outcomes come from hooks and the probes, never a watcher.
