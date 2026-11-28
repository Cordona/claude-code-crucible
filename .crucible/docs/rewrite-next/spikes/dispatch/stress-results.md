# Stress test of the job chain: results

2026-11-26, Claude Code 2.1.332. One interactive session in auto mode: Opus main, haiku stand-in agents with trivial jobs. Design: `stress-design.md` (Fable-confirmed). Shapes: `job-event-shapes.md` draft 4. Kit: `kit-stress/` (setup.sh, go.sh, resolve.sh, card.sh, agent-files.sh, define.sh, cut.sh, door.sh, end-job.sh, work.sh, the hooks pre.sh, wt.sh, start.sh, post.sh and stop.sh, one jq rule per event type in `rules/`, audit.py). Sandbox: `/Users/Shared/crucible-sandbox/stress`. I acted as the human at the gates (`human.sh` gives the answer; `card.sh` writes `gate.answered`, `by: card.sh` in the log). Main read only `main-prose.md` (14 lines) as its CLAUDE.md.

## What ran

| Gate | Jobs | How |
|---|---|---|
| 5 | 2 builds (kotlin+spring, shell), trees cut from main | cold |
| 16 | a swarm of 10 reviews on job 6's tree (4 security, 2 persistence, 2 observability, clean-code, performance) | cold; 4, 2 and 2 jobs shared one kind+set file |
| 57 | review with its own cut; summary not on code; a review whose agent dies; a review printed hot and never sent | cold; dead → replaced (job 86); the last dropped |
| 62 | fix targets SEC-1, SEC-2, PERS-1: the first fix (job 63) | hot; then unattended loop rounds 1 (re-review 66) and 2 (fix 69, re-review 70), all hot |
| 90 | 2 jobs, one with an unknown kind | none defined |

21 jobs defined, 16 agents, 90 events.

## Pass lines

1. **Audit, from the log alone: pass.** 0 problems. Every job chains defined → tree (cut or `of`) → assigned → initialized (cold) with no break, miss or double. Each of the 16 agents has exactly one `agent.initialized`. Every gate-approved job equals the shown proposal entry it cites (21/21 checked, the loop and replacement jobs by their own rules).
2. **Trees and plugins, from the agents' transcripts: pass.** Plugins byte-equal for 16/16 agents, each preloaded once. The first job's pwd was the job's tree for 15/16; the 16th is the planted dying agent, which by design ran no command. The review with its own cut stood in `trees/j58`; the 10 reviewers and the replacement stood in job 6's tree; the summary (not on code) stood in main's checkout.
3. **Planted refusals: pass.** Each one was refused with its reason, and nothing else was refused (the refusal log holds only these):
   - Proposal changed after the card: "the proposal changed after the card was shown: nothing defined"
   - The door before the tree was cut: "job 58's tree isn't cut: run cut.sh"
   - Loop round 1 before the first fix handed in: "round 1 needs the earlier round's work handed in (jobs 63)" (an extra case, not planted)
   - Hot to an agent with the wrong plugins: "agent a9b2888678217ffab lacks language-kotlin, language-kotlin-build, framework-spring, framework-spring-build: start a cold agent"
   - Hot to an agent whose job is still open: "agent aed7cf43196b952a3 still works on job 66: one open job per agent"
   - A finding not chosen: "findings SEC-9 were not chosen at gate 62: a gate is needed"
   - Past the cap: "round 3 is past the cap (2): a gate is needed"
   - Two job agents in one reply: "one job agent per reply: start job 59 in your next reply"
   - An Agent call that isn't the door's: "this is not the call door.sh printed for job 59: send it as printed"
   - A proposal with one wrong job (unknown kind): "a job above is wrong: none of this proposal's jobs is defined"
   - A hot call printed and never sent: job 61 stayed unassigned, then was dropped with `end-job.sh`
4. **The loop ran with no human answer: pass.** Rounds 1 and 2 (jobs 66, 69, 70) were defined by `define.sh --loop`, with no card and no gate. Each was checked against gate 62's chosen findings, the cap and the earlier round's hand-in.
5. **Completeness, from the log alone: pass.**
   - Every defined job ended: 19 handed in, 1 dead and replaced (60 → 86), 1 dropped (61).
   - Per gate, shown = defined: 2/2, 10/10, 4/4, 1/1 plus 3 loop rounds; gate 90 showed 2 and defined 0 (all or none).
   - Resumed agents got no second `agent.initialized`. SubagentStart fired again on every resume (logged, nothing written), including 3 times for job 18's agent.
6. **Recorded.**

| Measure | Number |
|---|---|
| Permission asks | 0 |
| Classifier denials | 0 |
| Wasted rounds from the mechanism (unplanted refusals) | 0 |
| Main's calls, one cold job on code (gate 5) | propose: 2 Bash (resolve; card + agent files); run: define, cut, door = 3 Bash for both jobs, then 1 Agent per job |
| Main's calls, the swarm of 10 | 1 Bash to propose; define + door --ready, 1 Bash each; 10 Agent calls. Clean path: about 4 Bash + 10 Agent (the run had 3 extra door runs from kit bugs 1–2) |
| Main's calls, a hot loop job | 1 Bash for define (the round, all its jobs at once), 1 Bash for the door, 1 SendMessage |
| Door output for ready cold jobs, one run | 4,220 chars for 10 jobs (about 420 per job); 3,935 for 9 |
| Swarm wall time, first assigned → last handed in | 475 s, stretched by the two kit-bug restarts and main ending its turn after each start |
| Swarm agents alive at once | **7 at most, not 10** (see below) |

## Not met: ten agents alive at once

Most were 7, in the last batch (21–26 plus 20). Pairing and one-open-job held throughout (pass lines 1 and 3), but they were never tested with ten live agents. Two reasons:
- **Kit bugs 1 and 2:** the first two reviewers ran short.
- **The prose gap:** main read "one job agent per reply" as one per turn. It ended its turn after each start (jobs 6–7, 19–20) until it was told "one Agent call per message, the next as soon as the previous returns, in the same turn". After that, it started six in one turn.

## Kit bugs and prose gaps (cells rerun)

1. **A 90-second foreground `sleep` is blocked** by Claude Code for agents. Job 17 skipped its wait. I removed the stale notes for 18–26 and split the wait into 25-second steps.
2. **The split sleeps were blocked too.** Job 18's agent ran them in the background and finished early. The wait is now one timed step (`work.sh N`, not a sleep). Jobs 19–26 ran it. Jobs 17 and 18 still handed in, and their chains are clean; they just didn't overlap.
3. **Prose gap:** "one job agent per reply" was read as one per turn (above). The fix is prose: "one Agent call per message, the next in the same turn".
4. **Seen, not a bug:** main twice checked a card against its file and stopped instead of defining, once when the file had changed under it (the planted hash case, before define ran). The hash check then refused as planted.

## Findings for the design

- A job not on code stands in main's checkout (job 59: pwd `repo/`). With no tree, nothing keeps it off the human's files. That's fine for a reader; a writer needs a write scope.
- The card shows no inputs. Gate 62's card didn't list the chosen findings, so the human approved fix targets they couldn't see on it. The card needs the findings, the lens and the range.
- `resolve.sh` doesn't check the kind; the unknown kind reached the card and was refused only at define. A check before the card would save a gate.
- Sandbox noise: an MCP server in the sandbox config adds an instruction block to agents' tool output (Claude Docs). The agents ignored it. Not ours.

## Evidence

Events: `/Users/Shared/crucible-sandbox/stress/events/` (90). Refusals: `logs/refusals.log`. Kit bugs: `logs/kit-bugs`. Stage times: `logs/stages`. The audit is `python3 -I kit-stress/audit.py`. Transcripts stay local.
