# Stress 2: three repos, many agents (design, for Fable)

2026-11-26. Owner's go ("does it crack under pressure"). Same kit (`kit-stress/`), real `worktree-cut.sh`, shapes as in `job-shapes-final.md`, invariant 8. Stand-ins (haiku, trivial jobs that overlap), Opus main, one interactive session, auto mode.

## New in the shapes

A cut names its repo: `"tree": {"cut": {"repo": "/…/repo-b", "from": "ref:main"}}`. `use` needs none (the worktree.cut carries `repo`). Proposal and job.defined unchanged otherwise.

## Repos

- repo-a: Kotlin + Spring. repo-b: TypeScript + React. repo-c: shell.

## Scenario (about 40 jobs, 30+ agents)

1. Gate 1: 6 builds, 2 per repo, each cut from its repo's main. Cold.
2. Gate 2: 3 testers, one per repo, each on one of its repo's builds (`use`). Cold.
3. Gate 3, after the testers have ended (so invariant 8 lines are not expected): a swarm of 18 reviewers, 6 per repo, across the 6 builds; several share kind+set files. Cold, overlapping.
4. Gate 4: fix targets for 3 builds (one per repo), one gate. A loop is counted per gate and tree: each build's round, cap 2 and "earlier reviews in" are its own (the tree is already in the job; no new field). Fixes hot on the builders, re-reviews hot on reviewers. Pass: one slow build holds no other; one at the cap closes only its own.
5. Gate 5: a merged tree in repo-a from its two builds (`worktree:A worktree:B`), with one build on it.
6. Chaos, planted: a second writing job on a tree (refused); a reviewer on a tree with an open build (one line, main decides); a hot job to a reviewer of the wrong repo's plugins (refused); a cut naming a repo with a bad `from` (refused at the cut, dropped); a dead agent replaced; the held-but-unassigned tree case (Fable note 1) live; two Agent calls in one message (refused); the door given repo-b's worktree.cut for repo-a's cut job, both from "ref:main" (refused: the door compares the repo too); a reviewer of build A1 given a hot review of build A2, same repo and plugins (must be refused: "agent stands in tree X: start a cold agent"; if the rules lack it, it is invariant 9, for the owner).

## Where things live

Main stands in repo-a's checkout; agent files and plugin skills in repo-a's project `.claude`. Agents in repo-b and repo-c trees load them from main's project (recorded as a fact of the run).

Out of this run: read-only extra folders from another repo (no shape yet). No tracker call; scratch identity only.

## The door's wording (to Fable before it runs)

With its calls the door prints: "Send one per message; send the next as soon as this one returns, in the same turn." The one-per-message refusal says the same. No hint from me during the run.

## Pass

1. Audit from the log alone: every chain complete; each tree's repo matches its job; no tree with two open writing jobs.
2. Every agent in its tree, plugins byte-equal.
3. Every planted refusal with its reason; nothing else refused.
4. The loop unattended, within the cap.
5. Completeness per gate.
6. No hint: the swarm of 18 starts with no word from me about messages or turns.
7. Recorded: the door's and the start hook's running time early and late in the run, the longest lock wait, any hook timeout; peak agents alive at once (target 10+), wall time, replies and main's calls per job for the swarm of 18, door output size, main's context use by the end, permission asks, classifier denials, wasted rounds.
