# Live run: define and assign with the real builder, tester and reviewer

2026-11-27. One interactive Claude Code session, Opus 5.5, auto mode, on the sandbox's logged-in config (`/Users/Shared/crucible-sandbox/event-jobs/cfg`), the framework installed by `install-entries.sh`'s own links, the repo carrying the framework's `CLAUDE.md`. Setup and the plan fixture: `live.sh`. This first run's raw log was overwritten by a later collect (the sandbox it came from is reset); its chains below were checked against it before that, by Fable too. The later runs' logs: `out-build-rerun/events.json`, `out-trio/events.json`.

**Result: build, test, review cold and review hot each ran end to end on the new chain, with the real agents, the unchanged hand-in hooks, and every preloaded skill byte-equal.**

## The chains (from the log)

| Job | Kind | Chain |
|---|---|---|
| 16 | build | flow.agreed 11 → worktree.cut 12 (a flow and gate of its own, 10–14) → gate.answered 15 → job.defined 16 (cut from ref:main, a tree that already existed) → agent.initialized 17 → job.assigned 18 {job 16, tree 12} → build.submitted 19 (working commit 4cfaf31). The cut came before the jobs gate: the two-gates finding below |
| 24 | test | gate.answered 23 → job.defined 24 (tree use 12, plan 22) → agent.initialized 25 → job.assigned 26 → test.submitted 27 (working commit a7f33c7) |
| 29 | review, cold | gate.answered 28 → job.defined 29 (range main..a7f33c7) → agent.initialized 30 → job.assigned 31 → review.submitted 32 |
| 34 | review, hot | gate.answered 33 → job.defined 34 → job.assigned 35 by job-sent.sh, the same agent, no second agent.initialized → review.submitted 36 |

## Plugins

- Three agent files written by `agent-files.sh` at the card: `code-builder-shell-clean-code`, `code-tester-shell-testing`, `code-reviewer-shell-clean-code`; each started from the next turn.
- Each agent's transcript holds the full body of every skill it preloads, byte-equal: the builder's six (agent-conduct, agent-report, language-shell, language-shell-build, standard-clean-code, standard-clean-code-build), the tester's four, the reviewer's six.
- The tester got the base skills only (no plugin has a test part); the reviewer the `-review` parts.

## Guards, live

- An Agent call for a job agent not from the door: denied, "a job agent starts only from the call job-assign.sh printed".
- A tree start that is no job's (a general-purpose agent with `isolation: worktree`): first refused (the blocker Fable named); fixed in the run, it now gets a plain worktree as Claude Code makes one.

## Found and fixed in the run

1. The card's hint named agent-init's `agent-files.sh` without a path; main couldn't find it. It now prints the full command.
2. Resolve accepted a cut "from main"; `worktree-cut.sh` takes `ref:main`, so the door refused the mismatch (main recovered by defining the job again). Resolve now takes only the forms the cut script takes.
3. An empty context cut has no folder, yet the prompt named `context/v1`. A ref now names a file only when it is there.
4. The door printed `run_in_background`, a field the Agent tool doesn't take. Dropped.
5. The tree hook refused every tree start no job claimed. It now steps aside.

## Found, not fixed (prose, for the owner and Fable)

- **Two gates for one cut** (closed in the rerun below): git-worktree now asks for a gate only when no gate already showed the tree's repository and base.
- **The plan's approval** isn't an event in this run (the plan kinds aren't moved yet); main noticed and asked.
- **Main's own words.** Main changed "checkout" to "main" when it proposed the build. Its judgment in building jobs is still untested by design.

## Rerun of the build chain, after the git-worktree prose fix

Fresh sandbox, the same setup; the log: `out-build-rerun/events.json`. One gate for the job, and the cut follows it with no flow or gate of its own:

8 gate.answered (jobs) → 9 job.defined (cut from ref:main) → 10 worktree.cut → 11 agent.initialized → 12 job.assigned → 13 build.submitted

The two-gates finding is closed. Skill names shared with the old harness are not a risk: the owner removes the legacy framework at the real install.

## The test-plan trio, live (third run)

Fresh sandbox; the log: `out-trio/events.json`. Real agents, each from its own agent file, each one gate:

| Job | Kind | Chain |
|---|---|---|
| 9 | build | 8 gate → 9 job.defined → 10 worktree.cut → 11 agent.initialized → 12 job.assigned → 13 build.submitted |
| 15 | test-plan | 14 gate → 15 job.defined (tree 10) → 16 agent.initialized → 17 job.assigned → 18 test-plan.submitted |
| 20 | test-plan-challenge | 19 gate → 20 job.defined (plan 18) → 21 agent.initialized → 22 job.assigned → 23 test-plan.challenged: C-1 add, C-2 change |
| 25 | test-plan-update | 24 gate → 25 job.defined (plan 18, challenge 23) → 26 agent.initialized → 27 job.assigned → 28 test-plan.updated: C-1 and C-2 applied |

The rework's challenges reached it through the new chain, from the challenge's pinned report. Every agent's preloaded skills are byte-equal in its transcript (builder, tester twice, reviewer).

Found and fixed: main ran `job-card.sh` (which shows and records the jobs gate), then `show-card.sh` on the same card without `--record`, replacing the recorded card with a plain one, so the answer had no gate. `show-card.sh` now keeps the record when the same card is shown again without one, and `job-card.sh`'s help says it shows the card itself.

## The remote kinds, live (fourth run)

Fresh sandbox; the log is `out-remotes/events.json`, with the reports in `out-remotes/reports/`. One synthetic GitLab MR 42: a `--shout` change pushed to a local bare "host" the repo reaches through `insteadOf`, and a `glab` stand-in answering its review in the shape the live reads showed (`remotes-live.sh`). The reviewer is real. Nothing was posted anywhere.

| Job | Kind | Chain | Result |
|---|---|---|---|
| 10 | foreign-review | 8 remote-change.fetched → 9 gate → 10 job.defined (resolve filled the cut from the MR head, and the range) → 11 worktree.cut → 12 agent.initialized → 13 job.assigned → 14 foreign-review.submitted | Found the `echo` regression (high) and the ASCII-only `tr` (low) |
| 17, 24 | external-review | 15, 22 remote-review.fetched (4 threads, `--bot review-bot`) → gate → job.defined (change 8 filled via the review) → assigned → job.refused → job.ended | Refused: the range was the tree's, empty on a tree cut at the MR head |
| 30 | external-review | 29 gate → 30 job.defined (the range now from the change) → assigned → 33 external-review.submitted | One verdict per reviewer point; the fixer's notes read as context; the resolved thread noted |
| 36 | external-review | 34 remote-review.fetched (unchanged) → gate → 36 job.defined → assigned → 39 external-review.submitted | The facts asked for nothing (`judge: []`); the agent judged every thread again, and the `tr` point drifted from valid to deferred |

Found and fixed in the run:
1. **An external review's range is its change's** (`range: "change"` on a used tree adds the range), not its tree's. Jobs 17 and 24 were refused over an empty range.
2. **A start Claude Code refused** (the agent file wasn't loaded until the next turn) left its door claim behind, which blocked every retry of the same job for ten minutes. A claim of the same job is now taken over; jobs-2 has the case.

Found, not fixed:
- **The second pass re-judges** (Fable's gap, now shown live). The comparison reaches the report check but not the agent, so an unmoved AI review is judged again and can drift. The proposed fix is Fable's: give the agent its earlier report as a ref, plus one prose line.
- **Main relayed refused reports as verdicts.** For jobs 17 and 24, the agent's message reached the human although the report was never accepted, and the agent ended without repairing it. Main should report from accepted submissions only.
- **Main's judgment held up:** on an unchanged fetch it declined to re-judge on its own, and it caught the drift between two passes.

### After the `earlier` fix: the changed case (same session)

The stand-in's review moved: the human added a reply in the line thread, and the bot edited its note (a new point 4). The resolved thread didn't change.

| Job | Chain | Result |
|---|---|---|
| 42 | 40 remote-review.fetched → gate → 42 job.defined (`earlier 39`, filled by resolve, job 36's accepted report) → assigned → 45 job.refused → 46 job.ended | Refused: the agent copied stamped `source` fields from its earlier report. Fixed: a `source` equal to the thread's opener's is accepted |
| 48 | 47 gate → 48 job.defined → assigned → 51 job.refused → 52 job.ended | Judged the two changed threads (the edited bot note: all 4 points; the line thread with its new reply). The bot's point 3 kept job 36's verdict, `deferred`: no drift. The unchanged resolved thread was still touched, `noted`. Refused over a finding in a test file outside the change |

Main told the human what had moved before proposing the job, and it described every refused job as refused.

**Found, not fixed:** a backgrounded agent ends through Claude Code's `SubagentHandback`, which delivers its report. The stop hook's refusal then comes too late to restart it: jobs 17, 24, 42 and 48 each ended after one refusal, with no repair. This touches every kind, so it is task #86, a probe first.

**What the changed case shows, and what it doesn't** (corrected after Fable's review): jobs 42 and 48 both ended refused, and the log stops at 52. What job 48 shows about the agent's judging is read from a refused report. So the `earlier` fix is shown to steer the agent, but the chain for the changed case has not closed green. It needs one accepted pass once repairs work (task #86).

**The headline of this run is the handback finding.** If a backgrounded agent can't be sent back, then "refused, repaired, accepted" has never been shown live for any kind, and every refusal costs a whole new job behind the human's gate. Probe first, with no design around it until the probe says what the harness really does.

## Fifth run: the handback door in place

Fresh sandbox, the same synthetic MR 42 (`remotes-live.sh`); the log is `out-remotes-run5/events.json`. The sandbox repo's settings carry the new PreToolUse hook on `SubagentHandback` (`agent-submission/hooks/pre-tool-use/hand-in-at-handback.sh`, which runs the stop hook's own script).

| Job | Kind | Chain | Result |
|---|---|---|---|
| 10 | foreign-review (clean-code) | 8 remote-change.fetched → gate → 10 job.defined → 11 worktree.cut → assigned → 14 foreign-review.submitted | Accepted |
| 17 | external-review | 15 remote-review.fetched → gate → 17 job.defined → assigned → 20 external-review.submitted | Accepted |
| 23 | external-review, the changed case | 21 remote-review.fetched (a new reply, an edited bot note) → gate → 23 job.defined (`earlier 20`, filled by resolve) → assigned → 26 external-review.submitted | Accepted: the changed case is closed green |
| 28 | foreign-review (testing) | gate → 28 job.defined → 29 worktree.cut → assigned → 32 foreign-review.submitted | Accepted |

**No refusal came up, so a real agent's "refused, repaired, accepted" is still not shown live.** It is shown in two halves:
- **The harness:** the probe (`spikes/handback/probe-results.md`) shows a denied handback repaired and handed back again in the same run.
- **Our hook:** build-agent's handback cases show a refusal at the handback with its repair lines, the repaired hand-in, the stop after it passing with no second submission, and the second refusal ending the job.

A twice-refused job didn't come up either. So Fable's question, what main does when it resumes that agent on its own, is still open.

**Which door wrote run 5's submissions:** the handback door, all four. Each submission is stamped in the same second as the agent's `SubagentHandback` returned "Report delivered", and before it returned (submission 14 at 06:48:51Z, the handback's result at 06:48:51.952Z; likewise 20, 26 and 32). The stop hook runs only after the handback's result. So the installed handback hook firing for a real job agent and writing its submission is live.

A side note from job 17's agent transcript: auto mode's classifier said it "gave no verdict for Bash: a hook changed this call's" input. That was agent-submission's Bash time-limit step, and the call went on.

## Sixth run: one seeded attempt at a live refusal

Fresh sandbox; `SEED=1 remotes-live.sh setup` plants a plain defect outside the change: on `main`, before MR 42 is cut, `tests/greet_test.sh` is made a test that can never fail. One foreign review through the testing lens, the same rule that refused job 48 in run 4. The log is `out-remotes-run6/events.json`.

**Result:** 9 gate → 10 job.defined → 11 worktree.cut → assigned → 14 foreign-review.submitted, accepted first time. The reviewer found the planted defect and reported it the right way: `tests/greet_test.sh:3-4`, `relates_to` `bin/greet.sh:7-9`, `out_of_scope` with its proof. The rule had nothing to refuse.

**So, as agreed with Fable:** "refused, repaired, accepted" with a real agent is **not proven live; first seen in real use**. Each half is proven:
- the harness repairs a denied handback (the probe);
- our installed hook fires at a real agent's handback and writes its submission (run 5, all four);
- our hook refuses, takes the repair and writes no second submission (build-agent).

**Watch item for real use:** a job refused twice, and what main does when it resumes that agent on its own. Not provoked.
