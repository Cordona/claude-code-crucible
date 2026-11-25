# Spike: event-driven jobs (spec, 2026-11-23)

By Dev Beta, for the owner, to be checked by the Crucible Fable Reviwer. It is a spike: it proves mechanics with stand-ins, and nothing in it becomes new-rewrite code. Nothing runs before the owner's go.

## 1. What it must prove

The owner's claim: **if the events are guaranteed, main needs only thin prose.** Main dispatches through scripts, scans the events when it stops, and either does the owed step or offers the next one. The spike proves or breaks that, for every scenario discussed on 2026-11-23:

1. **Every job emits its events, always:** `job.dispatched`, `job.assigned`, then exactly one of `*.submitted` or `job.ended` (with its reason). This holds for cold and hot delivery, a good end, a stop check that gives up, an agent stopped mid-work, and a cancel.
2. **Every event can be traced back:** each event names its job, its round and its root, and the agent's identity, so a script can walk any event back to the build or request that started the chain.
3. **The scan is right:** main's Stop scan says, for every root, either "owed inside an agreed step" (the stop is held, and the reason names one script) or "a fact for the next step" (shown, never held). It never holds for waiting on an agent. Several roots in one effort never mix.
4. **The auto-pilot loop runs with nobody typing.** It goes from `fix.chosen` (with a cap) to the end card, and is woken only by agents ending and held stops. That covers the harvest, declines, insist, the arbiter, a replacement, the cap, and the human's stop.
5. **Main's prose stays thin, and nothing else instructs main.**
   - `main.md` has at most 25 lines, saying what to do when.
   - Every other piece of prose main reads is counted beside it: each hold reason, each fact line, and every `--help` main opened.
   - The total is reported next to the size of what the old rewrite needed for the same ground: the build, test and review flow skills and the seat-run references.
   - **The human's answers are human words,** written before the run and kept as evidence: "yes, review it", "fix high and medium, three rounds", "stop the loop". They never carry kinds, groups, hot or fresh, or steps.
   - **`act` is attached by `job-dispatch.sh` from the fixture.** Main never sees it or passes it.
   - **Hot or fresh** comes from one neutral line in `main.md` ("reuse an agent that suits the job unless it ended badly") or a script default, never from the answers.

**Out of scope:** review quality, real plugins, real languages, cost, prompt injection, the human-facing card design, and the old flow skills.

**Not tested, and said in the results:**
- how the facts meet an agreed adaptive flow, since the lab has no flow;
- a real permission mode. The lab runs with permissions bypassed, and in real use a prompt to an absent human would stall the loop.

## 2. Lab

- **Place:** `/Users/Shared/crucible-sandbox/event-jobs/`, outside the home folder so the owner's `CLAUDE.md` doesn't load (memory: sandbox-outside-home). It has its own config folder like c4-prompt's, logged in by the owner once, and runs in tmux `crucible-ej`. The spike's scripts live in `lab/`; the fake project repo is `repo/`, with a bare `remote.git`; the events are `effort/events/`.
- **Nothing outside the lab is touched:** no `~/.claude`, no real repo, no network, and no keys (commits unsigned, with a lab identity). Cleanup happens on the owner's go.
- **Me as the human:** in live runs I answer every gate through tmux, by a script fixed before the run (memory: validator-drives-scenarios), and never ask the owner.

## 3. Stand-ins

### 3.1 Agents

These are five lab agent definitions. Each reads its job file (`JOB: <path>` is its whole prompt; the payload stays in the file, Fable's fallback) and does what the payload's `act` field says, nothing else. So every run is deterministic and needs no judgement from the agent.

| Agent | Tools | What `act` can say |
|---|---|---|
| `lab-builder` | Read, Write, Edit, Bash | write these files; answer these finding IDs done or declined; write no report (to trigger the give-up); write a broken report once |
| `lab-tester` | Read, Write, Edit, Bash | write a test file; write a plan draft; apply or mark `cannot` for each challenge |
| `lab-reviewer` | Read, Write | raise these findings (kind, file, severity, realism); answer earlier IDs fixed, open, withdrawn or insisted; for an external review, judge these threads |
| `lab-challenger` | Read, Write | raise these challenges on a plan |
| `lab-arbiter` | Read, Write | rule each key `fix` or `drop` |

The `act` scripts are written into the fixture before a run, so a run is the same every time.

### 3.2 Scripts and hooks, spike-only, in `lab/`

| Piece | Kind | Does |
|---|---|---|
| `ev.sh` | lib | appends an event: seq, type, at, job, round, root, agent, body; refuses a missing link; holds a lock |
| `job-dispatch.sh` | main | writes `job.dispatched`; refuses as listed in 3.3; prints the Agent or SendMessage call main must make |
| `pre-agent.sh` | hook, PreToolUse on Agent | refuses a job agent type without a valid `JOB:` line, or not in the background; writes nothing |
| `post-agent.sh` | hook, PostToolUse on Agent | writes `job.assigned` with the agentId and the identity name |
| `pre-send.sh` / `post-send.sh` | hooks on SendMessage | refuse a send to a job agent without a valid `JOB:` line; write `job.assigned` after the send succeeds |
| `scope.sh` | hook, PreToolUse inside agents | finds the job by `agent_id`; refuses a write outside its scope (a reviewer: its report path only); refuses an agent with no job |
| `agent-stop.sh` | hook, SubagentStop | validates the report, and refuses it when the tree's tip is not the job's commit; commits a build or test; writes `*.submitted`; after the second refusal, writes `job.ended {reason: gave-up}` and lets the agent end. If the events lock is held, it waits for the release, so there is one commit and one event. The commit names its job, so a commit whose event failed can still be recorded |
| `job-end.sh` | internal | `job.ended {reason: cancelled \| died}`; a replacement job names `replaces` |
| `round.sh` | internal | one round event with its whole set, base and head pinned, and the cover (files, threads or plan, plus the chosen findings' files); in a loop, derives the swarm |
| `merge.sh` | internal | gives finding IDs unique in the effort, statuses and the verdict: `review.merged` |
| `choose.sh` | main | records the human's choice from a **query** the script resolves (D4), such as `--severity high,medium --cap 3`, never a list of IDs; also a waiver, `loop.stopped`, comments to post |
| `harvest.sh` | internal | computes the next fix targets by the rule in Fable's loop answer, section 1 |
| `busy.sh` | internal | the tree rule: a writing job needs no open job on the tree; a reading job needs no open writing job |
| `owes.sh` | internal | per root: the owed step or the facts. Rules are declared per component in `lab/owes.d/` (build, test, review, external, foreign), and the scan asks each one |
| `main-stop.sh` | hook, Stop on main | runs `owes.sh`; holds the stop only for an owed step; prints the facts once; a refused step ends the loop with its reason. A hold reason is one line in a fixed, checked form: `owed: sh <script> <args>`. A fact is one line: `fact: <words>` |
| `orphans.sh` | internal, run by `main-stop.sh` | finds jobs assigned with no end whose agent is gone. Gone means `job.assigned` carries another session's id than the running one: a background agent doesn't outlive its session. It then writes `job.ended {reason: died}` for each. So a death is written by code, not by main |
| `remote.sh` | internal | a fake PR as a JSON file in the lab: fetch threads, post replies or comments, push a new head |

### 3.3 Refusals that must fire (each one is a case)

`job-dispatch.sh` refuses:
- a hot agent whose type doesn't fit the kind (a builder given a review);
- a hot agent with an open job;
- a reviewer of a commit it made;
- a tree that `busy.sh` says is busy;
- a gateless dispatch that no approval covers. The loop covers fix jobs, re-review by the kinds the first swarm had, and the arbiter, with a `fix.chosen` that has rounds left on the root and no `loop.stopped`. The second plan job is covered by the human's yes to the test-plan job. A new kind or a build is never covered;
- a second replacement for one slot.

The owed-step scripts refuse a repeated step, because main is woken once per ending agent: a second merge of one round, a second round for one fix, a second choice on one merge.

**Who writes each end:**

| End | Written by |
|---|---|
| a valid report | `agent-stop.sh` |
| the stop check gave up | `agent-stop.sh` |
| a cancel (main used TaskStop, or the human said stop) | `job-end.sh`, from the script the hold names |
| a death (the session closed while the agent worked) | `orphans.sh`, at main's next stop |

Stage B also logs what fires when an agent is stopped with TaskStop. If SubagentStop runs, `agent-stop.sh` writes the end itself.

The hooks refuse:
- a foreground job agent;
- a job agent with no `JOB:` line;
- an agent with no job writing anything;
- a reviewer writing outside its report path;
- a report that fails validation (the stop check).

## 4. Stage A: offline replay, no agents

- **Each case is a folder:** a fixture script that writes its events by calling `ev.sh` (never by hand), and the expected output of the script under test (`owes.sh`, `harvest.sh`, `merge.sh`, `busy.sh`, `choose.sh` or `job-dispatch.sh` in check mode).
- **Expected outputs are written first,** from the two Fable answers and the old decisions, before any script exists. Fable reads the case folders before the build.
- **A case passes only on an exact match,** checked by script.

- **A1, the chain:**
  - a build submitted → the fact "no review";
  - a round with 2 of 3 submitted → waiting, not held;
  - 3 of 3 → owed: the merge;
  - merged → owed: the choice gate;
  - two builds, then one round covering both → both "no review" facts clear.
- **A2, the loop (Fable's list):**
  - a fix, then clean;
  - targets left;
  - a decline accepted;
  - a decline insisted;
  - declined again and ruled `fix`;
  - ruled `drop`;
  - the cap used up;
  - a dead job replaced;
  - a second death;
  - the human's stop;
  - a second `fix.chosen` at the cap (a new count);
  - one `fix.chosen` leading to two fix jobs (production and tests) → the next round waits for both;
  - a fix with every finding declined → no commit, and the round is still made;
  - a deadlocked key → not given to a re-reviewer in its round, only to the arbiter.
- **A3, the end states:**
  - gave up, cancelled or died inside a round → the round waits for a replacement or closes with the gap shown;
  - a replacement counted once.
- **A4, the roots:**
  - two builds and two rounds in one effort, interleaved → no mixing;
  - a fix covering findings from two rounds → IDs unique, both rounds' findings answered.
- **A5, the cover:**
  - the second round's cover includes the chosen findings' files when the fix didn't touch them;
  - skipped findings are listed to the re-reviewer;
  - the fix job's file holds only the chosen findings;
  - `choose.sh` resolves a query, and refuses a query that matches nothing.
- **A6, busy:**
  - a fix while a round reads the tree → refused;
  - a tester and a builder on one tree → refused;
  - two reviewers → allowed.
- **A7, the kinds:**
  - a test submitted → its review;
  - a plan draft → challenge, then a second plan job with no gate, then the plan gate;
  - an external review received → a judging round, the loop, then the replies owed at the end;
  - a foreign PR → a round, the comment choice, a new head with replies, then a delta re-review;
  - a cold internal review of an imported range.
- **A8, facts versus held stops:** a fact once answered (the human said no) is not shown again; no owed step ever names waiting on an agent.
- **A9, refusals:** every `job-dispatch.sh` refusal in 3.3.
- **A10, repeated steps:** a second merge, a second round for one fix and a second choice are each refused, and the scan's answer is unchanged.
- **A11, deaths:** a job assigned with no end and its agent gone → `orphans.sh` writes `job.ended {reason: died}` once.

## 5. Stage B: hook runs, headless

A short `claude -p` per case in the lab, the way the two probes ran. Each one checks one hook refusal from 3.3, plus one good cold and one good hot delivery, by the logged hook input and the events written. B also re-checks the probes' facts with the lab's own hooks:
- PostToolUse sees the rewritten input;
- the `agentId` matches the agent's `agent_id`;
- a resumed agent's end reaches main.

Four more B cases:
- the events lock is held while an agent stops → one commit, one event, after the release;
- a report is refused because the tree's tip was moved by hand;
- a second Agent call with a `JOB:` line already assigned is refused;
- main writing an event file directly is refused.

Plus a log of what fires when an agent is stopped with TaskStop: whether SubagentStop runs, with what input, and what main is told.

## 5a. The dry run: a scripted driver

`lab/driver.sh` plays main and the agents for every C run, with no model:
- it feeds the real lab hooks the input they would get;
- it calls the real scripts in the order a correct main would.

Its event sequence per root becomes the **expected sequence** of the live run. Every case that depends on bad behaviour (no report, a broken report) must show its refusal in the hook log.

## 6. Stage C: live, interactive

Each C run first goes through the driver dry run (5a), which gives it its expected sequence.

Main runs in tmux with **one instruction file of at most 25 lines** (`lab/main.md`, loaded as the lab's `CLAUDE.md`). Its whole content is:
- dispatch only through `job-dispatch.sh`, making the call it prints;
- a held stop names a script: run it;
- facts: offer them in one line;
- gates: AskUserQuestion, then `choose.sh`.

Nothing in it is about any one scenario. I play the human from a fixed answer file of human words. `main.md`'s hash is recorded before C1 and checked after the last run.

| Run | Scenario | Must show |
|---|---|---|
| C1 | Build, cold review by 3, merge, choice with cap 1, a fix by the hot builder, a re-review by 2 hot reviewers and 1 fresh (the fixture made one reviewer end badly, so it can't be reused), end card | the full chain; hot delivery; assign after send |
| C2 | The same with cap 3: round 2 leaves targets, including a new HIGH from the fix; round 3 is clean | no human input between the choice and the end card; about four held stops per round; the resumed builder's end wakes main every round |
| C3 | Declines: one accepted (`withdrawn`), one insisted then declined again → the arbiter in the round's set → ruled `fix` → fixed | the arbiter job; one per round |
| C4 | End states: a reviewer that writes no report (gives up), a reviewer stopped by TaskStop (died), a replacement, then a second death in the loop | `job.ended` every time; the round closes; the loop ends with its reason |
| C5 | The human says "stop the loop" mid-round | `loop.stopped`; the next agent's end starts nothing |
| C6 | Two builds in one effort at once, each reviewed | no mixing; busy refusals visible |
| C7 | A test job, its review, and the plan challenge with the gateless second plan job | the kinds differ, the mechanism is the same |
| C8 | External review of our fake PR: fetch, judging round, fix, re-review, replies posted | the root holds to the end |
| C9 | A foreign fake PR: round, comments posted, the author pushes, delta re-review | the new-head row |
| C10 | The session is closed twice and reopened: once while a reviewer is working (the real death), once while nothing runs | `orphans.sh` writes the death; the next stop finds the same owed step; nothing is lost. The one reopening message is counted as the only input |

**Repeats and order:**
- C1 runs twice and C2 three times; results are reported as n of n.
- The order is C1 to C6, then C10, then C7 to C9. C7 to C9 are the ones to cut if time is short, since Stage A already proved their rows, and the results say what stayed offline only.

**Fail rules, checked by script:**
- **the sequence:** each run's events, per root, are compared with the driver's expected sequence;
- **nobody typed:** every keystroke the tmux driver sends is logged with its time, and any send between `fix.chosen` and the end card fails the run;
- **only named steps:** main's tool calls in the loop are listed from the PreToolUse log. Anything that is not a named script, the call it printed, or a gate is reported, and a run where main asks the human or does an unnamed step fails, even if the loop finishes;
- **also recorded:** how many holds came in a row, and the model and effort main ran with.

Each run's evidence:
- the events folder;
- a timeline that `owes.sh` prints after every event (`lab/timeline.sh`);
- the hook logs;
- main's transcript, which I read as the validator (no hook reads it);
- a pass or fail line against the run's expected sequence, written before the run.

## 7. Order and stop rules

1. Fable checks this spec against the owner's words and the two Fable answers (spike step 2). I fix the blockers.
2. Owner's go.
3. Build the lab. Stage A until it is all green, then Stage B, then the driver dry run for every C run, then the live C runs.
4. **Stop and report** at the first stage that breaks the claim: a missing event, a mixed root, a hold on waiting, or human input needed inside the loop. A Stage A failure is a failure of the model's logic and stops everything; a failure in C7 to C9 is a missing row. Don't patch prose to pass it (memory: script-not-prose-fixes).
5. Write `results.md`: pass or fail per case and run, n of n for the repeats, the prose total beside the old size, and what was shown only in the dry run (a crash inside the harness can't be staged). Fable judges it against the evidence, on the owner's word.

## 8. Settled points (from Fable's check)

- **"70%" for hot reuse:** no hook can see an agent's context. In the spike, hot or fresh comes from the neutral line and the fixture, which is enough, since hot or fresh is not what is being proven.
- **"Died":** TaskStop stands in for a cancel. The real death is a session closed while an agent works (C10), written by `orphans.sh`.
- **The 25-line cap stays,** but the measure is the total of all the prose main reads, beside the old size.
- **The repeats:** C2 runs three times and C1 twice.
