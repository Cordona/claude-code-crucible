# Stress 2: three repos, many agents: results

2026-11-26, Claude Code 2.1.332. One interactive session in auto mode: Opus main, haiku stand-ins.
- **Design:** `stress2-design.md` (Fable-confirmed), plus the owner's repo-join amendment and Fable's three records for it. **Fable has not seen the amendment itself.**
- **Kit:** `kit-stress2/`, the tree kit extended with three repos, `{"cut": {"repo", "from"}}`, invariant 8, the loop counted per gate and tree, and timing logs.
- **Framework pieces:** the framework's own `worktree-cut.sh` (unmodified, byte-identical), `effort-start.sh`, `event-write.sh`, `events-read.sh`, and git-identity's scripts with the gate's real hooks.
- **Sandbox:** `/Users/Shared/crucible-sandbox/stress2`. Main stood in repo-a's checkout; the agent files and plugin skills sat in repo-a's project `.claude`.

**The run:** 47 jobs, 34 agents, 195 events, 8 trees cut (one a signed two-tree merge), across 8 gates plus 7 unattended loop rounds.

**Restart:** try 1 ended repo-a's builds inside one turn, before the repos could be added. The sandbox was rebuilt and gate 1a rerun; try 1's refusals are kept in `logs/try1-refusals.log`.

## Pass lines

1. **Audit from the log alone: pass.** 0 problems.
   - Every chain is complete, and every `job.assigned.tree` is a `worktree.cut`.
   - A cut job's tree has the job's repo and `from`; a `use` job's tree is its `use`.
   - No `worktree.cut` is two cut jobs' tree, and none has a job field.
   - No tree had two open writing jobs at once (checked over every pair of assigned-to-ended intervals).
2. **Every agent in its tree, plugins byte-equal: pass.** 34/34 stood in their job's tree (pwd), and 34/34 had their plugins byte-equal, each loaded once. The repo-b and repo-c agents loaded the plugins from main's project (repo-a's `.claude`), a fact of the run.
3. **Every planted refusal with its reason, nothing else refused: pass, with one kit bug.**

   | Planted case | Result |
   |---|---|
   | A cut tree held by another job's printed start (Fable note 1, live) | "worktree.cut 8 is held by job 5's printed start" |
   | repo-b's cut given to repo-a's cut job, both "ref:main" | "worktree.cut 10 is of …/repo-b; job 5 cuts in …/repo-a" |
   | A hot review to a reviewer with the wrong repo's plugins | "agent ac00b86ba2469ae89 lacks language-typescript, language-typescript-review, framework-react, framework-react-review: start a cold agent" |
   | Past the cap on one tree | "round 3 is past the cap (2) on tree 29: a gate is needed" |
   | A bad `from` in repo-c | refused at the cut: "--from ref: nosuch is no commit of …/repo-c"; the job was dropped |
   | Two Agent calls in one message | "one job agent per message: send one per message; send the next as soon as this one returns, in the same turn (job 174 not started)" |
   | A second writing job on a tree | "tree 167 has an open build, job 184: one open writing job per tree" |
   | A reader beside a writer | the door printed "tree 167 has an open build, job 184" with the call. Main decided to hold the review until the build ended, then ran it. |
   | A dead agent | ended dead and replaced (job 112), cold |

   - **Kit bug:** the scenario generator split finding ids on dashes ("B, 1, B, 2"), so 4 refusal lines (2 defines) in round 1 are mine, not the mechanism's. The rule refused them correctly. The files were fixed and the round went through.
   - **First busy-tree attempt (gate 6):** the build handed in before main reached the doors, so the two invariant 8 cases were rerun at gate 7 with a longer build.
4. **The loop ran unattended, within the cap, counted per gate and tree: pass.** One fix-targets gate (133) covered three trees, with 7 rounds and no card.
   - Repo-a's fix was slow (90 s). Repo-b's and repo-c's round 1 were defined and ran before it handed in, so the slow build held no other tree.
   - Repo-c reached the cap. Its round 3 was refused, and repo-b's round 2 was accepted after that, so the cap closed only repo-c's loop.
5. **Completeness per gate: pass.**
   - Every gate showed n jobs and defined n: 3, 4, 3, 18, 3 + 7 rounds, 2, 3, 3.
   - Every defined job ended: handed in, replaced (1), or dropped (3: the early repo-b build, the bad `from`, and the invariant 9 job).
6. **No hint: pass.** I said nothing about messages or turns. The door printed its line with each call. Main started the swarm of 18 one per message in a single turn (19 Agent calls in that stage, one of them the replacement), with no refusal. The only one-per-message refusal came from the planted two-in-one case.

## Gap: invariant 9 (for the owner)

A reviewer of build A1 was given a hot review of build A2: same repo, same plugins. The agent stands in tree 8 and the job is for tree 9. **The door accepted it and printed a SendMessage.** No rule covers it; I didn't add one. Main spotted the gap itself: "a hot send from it would run the review in the wrong tree". It wasn't sent, and the job was dropped. It needs invariant 9: a hot job's tree must be the tree the agent stands in.

## Did it crack? The numbers

| Measure | Number |
|---|---|
| Peak agents with an open job at once | **18** (target 10+) |
| Door time, early vs late (median of the first and last 10 of 52 runs) | 0.14 s vs 0.15 s; max 0.16 s |
| Start-hook time, early vs late (median of the first and last 8 of 44) | 0.34 s vs 0.38 s; max 0.41 s |
| Event write, lock wait included, early vs late (median of the first and last 46 of 230) | 0.11 s vs 0.12 s; **longest 0.15 s** |
| Hook timeouts | 0 (none in main's transcript, no start errors) |
| Swarm of 18: wall time, first assigned → last handed in | 183 s |
| Swarm of 18: main's replies and calls | 70 replies; 6 Bash (define, door runs) + 19 Agent (18 plus the replacement): about 1 Agent call per job plus a shared handful of Bash |
| Door output | median 746 chars, max 9,162 (the ready list) |
| Main's context at the end | about 181 K tokens (179,869 cached plus 1,048 new), after 263 replies and 117 tool calls |
| Permission asks / classifier denials | 0 / 0 |
| Wasted rounds from the mechanism | 0 unplanted refusals. Wasted from the kit: try 1's restart, the id-split round, and the first busy-tree attempt |

Nothing cracked at 18 live agents and 195 events: door, hook and write times stayed flat from the first event to the last. The cost that grows is main's context, about 181 K tokens by the end, mostly from relaying agents' completion notices.

## The repo-join amendment (Fable hasn't seen it)

- **How the repos were added:** in one go, while repo-a's two builds were running (jobs 5 and 6, assigned at seq 12 and 14, handed in at 20 and 21). It used what the framework has, git-identity per repo: 8 calls per repo (identity-list, identity-card ×2, show-card, the gate's 3 hooks, identity-set).
- **What it cost:** 2.3 s and 4 events, a `gate.answered` and an `identity.set` per repo (seq 15–18). `identity.set`'s body carries the repo.
- **Disturbance:** none. No refusal, no start error. Both builds handed in normally, about 90 s later, as set.
- **The new repos' agent files and plugins:** seen at the next turn, as before. The repo-b builder file was written at gate 1a and used at gate 1b; the repo-c builder file was written at gate 1b's card and started at the approval turn.
- **Fable's record 1, a cut on repo-b before repo-b was added:** it didn't stop anywhere. Resolve, define and the cut all went through ("job 7's tree cut: worktree.cut 10"), in both tries, because a `ref:` cut needs no identity. Only a snapshot or a merge needs one. The job was then dropped as planned.
- **Fable's record 2, can a reader tell from the log that repo-b and repo-c joined, and when?** Only indirectly.
  - There is no "repo joined" event.
  - The first trace of repo-b is `worktree.cut` 10 (seq 10), before its `identity.set` (seq 16).
  - For repo-c, the first trace is `identity.set` at seq 18; its first cut came later.
  - **Gap for the owner:** a repo's arrival in an effort is visible only as its first `worktree.cut` or its `identity.set`, whichever comes first, and the identity is needed only for signing.
- **Fable's record 3:** nothing in flight was refused, delayed or re-read.

## Kit bugs and deviations

- **Try 1:** no repo was added while the builds ran, because both builds ended inside one turn. The sandbox was rebuilt and gate 1a rerun.
- **The generator's finding ids** were split on dashes (above). Fixed.
- **Approval event:** as in the tree run, the human's approval is the kit's `proposal.approved {path, sha256}`, since core's `gate.answered` rule takes no `shown` field. The framework's `agent-jobs` component was left out of the installed skills folder.
- **Testers:** they load the language plugin, its frameworks and `standard-testing`. There's no test part, since no `test.md` plugin exists.

## Evidence

- Effort: `/Users/Shared/crucible-sandbox/stress2/space/efforts/*-tree-run/events/` (195 events).
- Logs: `logs/refusals.log`, `logs/timing`, `logs/repo-add`, `logs/kit-bugs`, `logs/stages`.
- The audit: `python3 -I kit-stress2/audit.py`.
- Transcripts stay local.
