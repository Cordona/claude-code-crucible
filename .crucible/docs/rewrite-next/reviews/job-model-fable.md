# The job model against every old review scenario: Fable's answer (2026-11-23)

By Crucible Fable Reviwer, for the owner, on `job-model-brief.md`. Talking only; nothing here is a go or a design.

I read the brief, `review-flow-decisions.md` (D1 to D17, O1 to O3), `review-events.md`, the "Partial reads" decision, the parked map, the constitution, and the probe's hooks and logged inputs. I ran nothing: the probe's logs are the evidence, and I did not repeat it.

## Verdict: works, with changes

**The job model carries every review scenario in the two documents.** No scenario needs a seat. Three things the old flow needed special cases for become the default: a reviewer with no Bash (foreign code), squads (file groups), and a fixer who never built the code (a fresh fix job).

**It is not complete as briefed.** The brief describes the path where every job ends well. Ten changes are needed; four of them are gaps that would break a real run:

1. A job has no way to end without a result.
2. "Target" changes every round, so grouping by target breaks at round two.
3. Nothing stops a fix from moving a tree that reviewers are still reading.
4. The table is a second answer to "what next", beside the agreed flow.

The full list is in section 6.

## 1. Each scenario under the model

Events marked *(new)* are ones the brief doesn't name. "Stop check" is the script the agent's stop hook runs.

### 1.1 Internal first review (D4, D7, D9, D12)

| Step | Event | Written by |
|---|---|---|
| The build ends | `build.submitted` (commit) | the builder's stop check |
| Main proposes the swarm on one card: kinds and file groups; the human agrees | the gate's answer | core's gate |
| The round is fixed with its whole set | the round event, with target, pinned base and head, and its jobs | the round script |
| | one `job.dispatched` per reviewer | the same script |
| Main starts each reviewer | `job.assigned` | the hook after the Agent call |
| Each reviewer reads the builder's tree and writes its report | `review.submitted` | the reviewer's stop check, which also refuses when the tree's tip is not the job's commit |
| The set is complete | `review.merged`: IDs, statuses, verdict | the merge script |
| The human chooses | `fix.chosen` | the choice script |

**Carried.** Two notes:
- **IDs at the merge, not at each stop,** is simpler than the old way: no lock between reviewers, and the old "last one acts" goes.
- **The review's range must be pinned on the round.** D1 allows several builds before one review, and the review then covers all of them. So a round's target is a range on a tree (base and head), and one round can be the follow-up of several `build.submitted` events.

### 1.2 Re-review after a fix (D5, D6, D8)

1. `fix.chosen`, then a fix job on the build's tree, usually to the hot builder: `job.dispatched`, `job.assigned`.
2. The builder answers each chosen ID, done or declined. Its stop check refuses a missing ID. `build.submitted` with the fix commit.
3. A new round on the fix: it reviews the fix diff only. Each reviewer's job carries the earlier findings in its files.
4. `review.submitted` per job, then `review.merged`, then the gate again.

**Carried, with four things to keep from the old decisions:**
- **Who answers an earlier finding.** The old rule was "the seat that raised it". The new one is "the reviewer of that kind that holds its file". A chosen finding whose file the fix did not touch (a decline, or a fix made elsewhere) still needs an owner. So the second round's cover is the fix diff's files plus the files of the chosen findings.
- **Skipped findings** (D8): the re-review job lists the findings in its files that the human did not choose, so a fresh reviewer doesn't raise them again as new.
- **A fix with every finding declined** changes nothing, so there is no commit (D6). The submitted event must allow that.
- **A fix job's `build.submitted` is not a build's.** It owes a re-review of the fix diff by the kinds that had findings, not a first review. The job's kind tells them apart.

### 1.3 Declines and deadlocks (D10, D11)

The old flow: the lens accepts or insists, an arbiter rules on a deadlock, and the loop runs without the human up to a cap. The brief has none of this: after every round the human sees the totals and chooses again.

**That is a change, and I think it is the right start.** A declined finding goes to the human at the next gate, who waives it or sends it back. This drops three record kinds (`withdrawn`, `insisted`, the ruling) and the arbiter, and it matches "what the human chose is mandatory; a decline needs the human's waiver". The cost is that the human is asked every round. If that proves heavy in live use, a `fix.chosen` that carries a cap can bring the unattended loop back without changing the model.

**It needs one event the brief lacks:** the human's waiver *(new)*, since a finding closes only through an accepted report or a recorded waiver.

### 1.4 Hot and cold reviewers

- **Cold:** a fresh agent per review job. Everything it needs is in the job: the diff, its files, the earlier findings. Carried.
- **Hot:** the same agent takes the next round's job through SendMessage. Carried, on three conditions the dispatch script must refuse on:
  - the agent's type fits the job's kind. A hot builder must never receive a review job: it holds Bash and Write, and the write scope would follow the job while the tools stay the builder's;
  - the agent produced none of the commits under review;
  - the agent has no open job.

### 1.5 Squads and partial reads (owner-decisions, "Partial reads")

File groups are the squads, and they are already what the old decision asked for: every reviewer gets the whole diff, no file has two reviewers of one kind, and a script checks the cover. **Carried, and earlier than planned.** The split by read size stays main's judgement; the size script can come when a live run asks for it.

### 1.6 Cold internal review (D13)

1. The human commits their own work; main proposes the swarm; the human agrees.
2. The range is recorded (the old `range.imported`), and a tree is cut at the head.
3. A round whose target is that range. From here it is 1.1.
4. The fixer is a fresh fix job on that tree, approved by the human's first fix choice.

**Carried.** It shows the target need not be a build. One old rule to decide again: "an effort that imported a range refuses a build". Under the job model that is "a job of kind build is refused there". Keep it only if the owner still wants it; pieces don't need it.

### 1.7 External review of our change request (D14, D16)

1. The fetch script writes `external-review.received`: the threads as a snapshot.
2. A round whose target is that event. Each job carries the snapshot's path; the reviewers read the tree at the change request's head.
3. `review.submitted` per job: every concern names its thread, may carry `rejected`, and nothing new is raised. Then `review.merged`, with valid, rejected and awaiting counts.
4. `fix.chosen` (the human may pick a rejected one), the fix job, and re-review rounds as in 1.2.
5. When the loop ends: main drafts one reply per thread, the human approves, the post script posts and records each post.

**Carried, as its own job kind.** It is not "the same job with another target":
- its report check is different (a concern without a thread is refused);
- its cover is by thread, not by file. Threads with a file go with that file's group; threads with none need an owner, the tech reviewer by default.

Step 5 is why the chain needs a root (section 3.2): "the replies are owed" is a fact about the first event, known only after the last round.

### 1.8 Foreign change request (D15, D16)

1. The link and the range are recorded; a read-only tree is cut at the head.
2. A round, `review.submitted`, `review.merged`, the gate. The human chooses which findings become comments.
3. Main drafts, the human approves, the post script posts; each post records its thread and finding.
4. The author pushes: the fetch records the new head and the author's replies; the tree moves on the human's go.
5. A re-review round: each job carries the delta from the old head to the new, the earlier findings in its files, and the replies, which stand in for a fix report.

**Carried.** The old special case "seats get no Bash" is now every reviewer. The table lacks the row for step 4.

### 1.9 Test plan challenge (D17)

1. A test-plan job: the tester's stop check writes the plan draft's event.
2. A challenge job, a review kind of its own, whose target is that draft. Its report holds challenges (kind, targets), not findings.
3. `review.submitted`; the script gives each challenge its key. A round of one job.
4. **No gate here.** A second test-plan job goes to the tester, hot by default, carrying the challenge. Its stop check refuses until every challenge is applied or listed as `cannot`.
5. The plan gate shows the totals. The human's change makes a new draft, and only what changed is challenged again.

**Carried, as its own kind**, and it is the scenario that differs most:
- a different report shape and a different stop check;
- no IDs that live across rounds, no verdict, no fix gate;
- **step 4 is a dispatch with no human gate.** The model must say what approval covers it (section 6, change 6).

"An identical change isn't challenged twice" is a small script compare; I would leave it out until a live run shows the repeat.

### 1.10 The test review (D4)

`test.submitted`, then a round by the test reviewer; the fixer is the tester. **Carried.** One case from the old open point O2: a cold review whose chosen findings touch both production and tests needs two fix jobs, production first. So one `fix.chosen` can lead to a set of fix jobs, and the next round waits for all of them: the same "expected set" rule as a round.

## 2. What the old documents decided that the model drops or changes

| Old decision | Under the job model | Fine, or a gap |
|---|---|---|
| The pass's expected set (D9) | The round, with its jobs | Fine, if the round is one event written with its whole set. If jobs join a round one by one, a round can look complete before its last job is dispatched. |
| "The last one acts", under a lock (D9) | Main's scan finds the round complete | Fine, and simpler |
| Stable IDs, unique per iteration (D5) | IDs given at the merge | **Gap:** no scope is stated. See 3.2. |
| Keys owned by the seat that raised them (D5, D8) | By kind and file | Fine, with the cover rule in 1.2 |
| One record per stop (events, point 10) | A job has one submitted event | Fine, by construction |
| The fix query: main translates, the script resolves, the human sees one totals line (D4) | Not stated | **Keep it.** Main never types the list of IDs. |
| The fixer gets only its targets (D4) | The analysis hands the fixer the merged report | **Keep the old rule:** the fix job's payload is a cut with the chosen findings only. |
| The re-review extract (D8) | The job's payload | Fine |
| Skipped keys are not raised again (D8) | Not stated | Keep, in the payload (1.2) |
| Accept or insist, the arbiter (D7, D10) | Gone; the human decides | Fine (1.3) |
| The unattended loop, the harvest, the cap (D9, D11) | Gone; a gate every round | Fine to start; a real change the owner should confirm |
| Iterations and commit trailers (D1, D5) | Gone | Fine, with two conditions: the root in 3.2, and the commit names its job, so a commit whose event failed can still be recorded |
| Re-seat when an agent dies (D9) | Not stated | **Gap.** See 3.1. |
| Cancel (the old `review-cancel.sh`) | Not stated | **Gap.** See 3.1. |
| Partial reads and squads | File groups | Fine (1.5) |
| The challenge's place and rules (D17) | A review kind and a second plan job | Fine (1.9) |
| One card for the swarm (D12) | The round's gate | Fine |
| The watcher, the account check, the double-post markers (D14 to D16) | Outside the job model | Still owed, by whichever piece fetches and posts |
| O3, someone else pushes to our change request | Not covered | Still open. The tip check doesn't see it: our tree's tip is unchanged, the remote moved. |

## 3. Does correlation hold?

**For the cold path, yes, from the probe.** For the rest, here is what holds and what is missing.

### 3.1 A job that ends without a result (the largest gap)

The brief has three job events: dispatched, assigned, submitted. Three real cases have no event:
- **The agent dies** before it submits.
- **The stop check gives up** after its allowed refusals.
- **Main or the human cancels.**

In each, the job stays "assigned, not submitted" for ever, the round never completes, and the tree stays busy.

**What I'd add:** one end event for a job with no result *(new)*, with its reason, written by a script. The stop check writes it when it gives up; main runs the script when it sees the agent is gone or the human cancels. A replacement is a new job that names the one it replaces *(new field)*, so the round counts the slot once.

**One reviewer never reports:** the scan says "the round waits on this job, assigned at this time". That is waiting on an agent, not on main, so it must not hold main's stop. Main checks the agent and waits, replaces it, or, on the human's word, ends the job and lets the round close with the gap shown on the card.

### 3.2 Two rounds on one target, and a fix covering two rounds

Both work only if two things are settled.

- **A root for the thing under review.** A round's target is the build; the fix produces a new `build.submitted`; the next round targets that one. So "target" is different every round, and "scans group by target" stops grouping at round two. Every event of a chain (rounds, merges, choices, fix jobs and their results, replies) should carry one root: the first build, the imported range, the received external review, or the foreign change request. This is what the old "iteration" did. Scripts could instead walk the chain backwards each time, which is more code and breaks when one link is missing.
- **Finding IDs unique in the effort.** Then a fix can take IDs from two rounds, or from two swarms on one build, with nothing to reconcile, and the human never sees the same ID twice. "Open findings of this root" is one read over the merges and waivers.

With those, two rounds on one target at the same time are safe: each report names its job, each job its round, and the merge gives IDs under the events lock.

### 3.3 A fix while reviewers are reading

A reviewer reads the builder's tree, and its report is refused when the tip moved. So a fix job dispatched while another round is still open on that tree makes every pending report of that round fail.

**The rule:** a tree is busy for a writing job while any job on it is open, a reading one included; a reading job needs only that no writing job is open. A builder and a tester share a tree, so this also replaces the old "pair hold". This is the `busy.sh` that `worktree-busy.sh` already asks each component for and nobody supplies yet.

### 3.4 Cold delivery

The probe shows what the brief says: one `tool_use_id` for both hooks, the rewritten prompt and `agentId` in the second, `agent_id` on the agent's own calls. Three precise points:

- **Background only.** The probe's agent ran in the background, where the second hook fires at launch. For a foreground agent it fires when the agent has finished, so `job.assigned` would come after all its work. The first hook must refuse a job agent that is not in the background, as the old one did.
- **There is one key, not two.** The first hook writes nothing, so the second has nothing to compare the `tool_use_id` with. What ties the two events is the job's path in the prompt. That is enough, because the first hook refuses every job agent without a valid line. Record the `tool_use_id` as a fact; don't describe it as a check.
- **A job agent with no job is refused, not allowed.** Between the launch and `job.assigned` there is a short window, and a second Agent call with the same line is possible. In both cases the agent's own hooks find no job for its id. They should refuse its writes with a plain reason. Core's hooks fail open on a fault; this is not a fault.

### 3.5 Hot delivery

Not probed, as the brief says. The model does not depend on the rewrite working:

- **A fallback that needs less:** the message stays `JOB: <path>`, and the agent reads its payload from that file. Then the hook only has to match SendMessage, see who it is for, and refuse. Probe that first; the rewrite is a convenience on top.
- **Write `job.assigned` after the send succeeds,** as on the cold path. Written before, a send that fails leaves a job assigned to an agent that never heard of it.
- **The address must be the agent's id,** which the dispatch script prints for main to use. The hook can match an id against `job.assigned`; it can't resolve a name.
- **"Refuses a message to a job agent without a `JOB:` line" is right, and it has a consequence to say out loud:** every word to an agent is a job. The human's change is a new job; a question about a report is answered by main from the report, which is why the report must stand alone.
- **"Under about 70%"** has no source I know of. A hook can't see an agent's context, and nothing reads transcripts. Either something reports it, or the rule is main's judgement from what it can see, such as how many jobs the agent has done. Decide which before it is written into a script.

That a resumed agent's stop fires the stop hook again, with the same id, is what the old rewrite's warm changes relied on in live runs. I take it as proven there, not here.

## 4. Against the constitution

- **Events written only by scripts (§4):** holds. The dispatch script, the two hooks, the stop checks, the merge. It holds for `fix.chosen` only if the query rule from D4 is kept.
- **Invariants in code (§3):** holds, and better than before: the job is the credential, the reviewer's limits are its tools, and the tip check is a refusal.
- **Small pieces (§1, §17):** the pieces fall out cleanly: jobs (dispatch, assign, stop, write scope, busy); review (round, merge, findings, choice); remote (fetch, post). **The one table is the exception.** A single script that knows builds, rounds, external reviews and foreign change requests couples every component to it. The catalogue already has the pattern: each component declares its own steps. Each should declare its own waiting rule the same way, and the scan asks them.
- **Hows, not flows, and the agreed pipeline (§5, §14):** this is where I push back hardest. The table's rows are of two kinds:
  - **What a finished round owes** (rows 2, 4 and 6): merge, then show the gate. These are the inside of a step the human already agreed. A script should say so, and may hold main's stop for it.
  - **What could start** (rows 1, 3 and 5): a review after a build, judging an external review, reviewing a foreign change request. These are choices of the next step, and the adaptive flow is where main and the human agree those. A table that offers a review after every build is a pipeline written in a script. If the agreed flow says build, then test, then review, the table and the flow disagree at the first stop.

  So: the starting rows become facts main can see ("this build has no review"), never a held stop. The agreed flow says what comes next; with no flow, main offers once, and the human's no is recorded and counts as the follow-up, so the scan doesn't ask again at every stop. The cold review shows the starting rows aren't needed: it starts from the human's ask, with no row at all.
- **No micromanaging prose (§6):** holds. Nothing here needs a step tree in a skill.
- **Small, then learn (§12):** the brief designs four flows at once. The model carries all of them, so nothing forces that. I would build 1.1 and 1.2 with the job's end states, run them live, and only then add the plan challenge, the external review and the foreign change request, each as a kind.

## 5. "Only the target and the last step differ"

Not quite, and the difference matters for what gets built. There are three review kinds with their own report and stop check:

| Kind | Report | Cover | After the merge |
|---|---|---|---|
| Code review (a build, a test, an imported range, a foreign change request, a fix) | findings | files | the human's choice |
| External review | a judgement per thread | threads | the human's choice, and replies at the end |
| Plan challenge | challenges | the plan | a second plan job, no gate |

The job, the round, the assignment and the merge's place are shared. That is the real saving, and it is large.

## 6. The changes, ranked

1. **A job can end without a result:** one end event with its reason, and a replacement job that names the one it replaces (3.1).
2. **A root on every event of a review chain, and finding IDs unique in the effort** (3.2).
3. **The busy rule for trees,** supplied as the `busy.sh` that `worktree-busy.sh` asks for (3.3).
4. **The table:** rows declared by their components; finished-round rows may hold the stop, starting rows are facts for the agreed flow; an answered offer counts as the follow-up; waiting on an agent never holds main's stop (section 4).
5. **The round is one event with its whole set, and its range is pinned.** One `fix.chosen` with several fix jobs uses the same completeness rule (1.1, 1.10).
6. **Say what approval covers a dispatch.** "A gate before dispatch" is one of the constitution's own examples. Three dispatches in the model have no gate of their own: the hot fix job after `fix.chosen`, the second plan job in the challenge, and a replacement for a dead agent. Each is covered by an earlier yes; the dispatch script should be able to name which.
7. **Cold delivery:** background only; one key; a job agent with no job is refused (3.4).
8. **Hot delivery:** probe matching and refusing first, with the agent reading its own payload as the fallback; assign after the send; the agent's type must fit the kind; settle where "70%" comes from (3.5, 1.4).
9. **Keep four old rules:** the fix query resolved by a script; the fixer sees only chosen findings; skipped findings are named to the re-reviewer; the second round's cover includes the chosen findings' files (section 2).
10. **Confirm two deliberate losses with the owner:** the unattended loop with its cap, and the arbiter (1.3).

Missing rows, once the table's form is settled: a test's review, the plan draft's challenge, a foreign change request whose head moved, and a fix with declines.

## 7. A caution on confidence

This is a paper check of a talk, against documents written for another machine. Two things carry real evidence: the cold correlation (the probe) and the review judgement itself (the old live runs). Everything about hot delivery, the scan and the table is a prediction. The model is simple enough that a small build of 1.1 and 1.2 would test most of this in one live run, and I would trust that run over this document.
