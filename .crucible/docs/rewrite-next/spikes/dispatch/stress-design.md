# Stress test of the job chain (design, for Fable)

2026-11-26. Owner's go. Mechanics only: stand-in agents (haiku, trivial jobs), Opus main, one interactive session, auto mode, sandbox under /Users/Shared. Shapes: `job-event-shapes.md` draft 4. Spike-grade scripts, one act each; no spec.

## Pieces (kit)

- `resolve.sh`: main's jobs → full jobs (latest context/spec/grills, range, iteration), from the log; input data per kind from one small table (stand-in of the core's step definitions).
- `card.sh`: shows the resolved proposal, writes it with its hash; I answer as the human, `gate.answered` with `shown`.
- `agent-files.sh`: kind+set agent files for the proposal; refuses a missing or hidden skill.
- `define.sh`: one `job.defined` per approved job from `shown` (all or none); a fix round: main's jobs checked against the loop's gate (findings subset, cap, earlier reviews in).
- `cut.sh`: `tree.cut` per job whose tree is cut.
- `door.sh`: checks a job (defined, tree there, unassigned; hot: base and plugins cover) and prints the exact Agent call or SendMessage; leaves the note for a cold start.
- Hooks: PreToolUse (the start is the door's call; one job agent per reply), WorktreeCreate (answers the job's tree path), SubagentStart (`agent.initialized` + cold `job.assigned`), PostToolUse SendMessage (hot `job.assigned`).
- `hand-in.sh`: the stand-in writes its report file; a stop hook writes `job.submitted` (stand-in of the real hand-in).
- `audit.sh`: reads only the log; every chain resolved; counts.

## Scenario (about 15 jobs)

1. Gate 1: 2 builds (kotlin+spring; shell), trees cut from main. Cold.
2. Gate 2: a review swarm of 10 on build 1 (4 security, 2 persistence, 2 consistency, 1 clean-code, 1 tech), standing in build 1's tree. Cold; two pairs share a kind+set file.
3. Gate 3: fix targets chosen from planted findings; its proposal holds the first fix only (hot: build 1's agent, `{gate, job: 1}`). Then unattended, main's jobs checked: round 1 a re-review (hot: one reviewer), round 2 a fix and a re-review. Cap: 2 rounds.
4. Refusals planted: a round-3 job past the cap; a round job with a finding not chosen; a hot job to an agent with the wrong plugins; a second agent start in one reply; an Agent call not from the door.
5. Tree cases: one job not on code (no tree; the start hook assigns with no tree hook); one reviewer with its own cut from a ref (no `pr` form: no tracker calls).
6. One replacement: a reviewer job ended as dead, replaced (`replaces`), cold.
7. One defined job dropped with `end-job.sh`.
8. Planted, more: define after the proposal file changed (hash); the door for a job whose tree isn't cut; a hot job to an agent whose job is still open; a proposal with one wrong job defines none; a hot call the door printed and main never sent (stays unassigned).

Stand-in jobs sleep long enough to overlap, so the swarm has ten agents alive at once. The hot step after a send finds its job from a note the door leaves for the hot call, as for a cold start.

## Pass

1. Audit: every job chains defined → (tree.cut or of) → assigned (→ initialized when cold) with no break, miss or double; each cold agent exactly one `agent.initialized`; job.defined equals the shown proposal entry.
2. Each cold agent stood in its job's tree (pwd) with its plugins (marker check).
3. Each planted refusal refused with its reason; nothing else refused.
4. The loop's rounds ran with no human answer.
5. Completeness, from the log alone: per gate, every defined job ended, replaced or dropped; a resumed agent got no second `agent.initialized`.
6. Recorded: wall time and replies for the swarm of 10; what main's context gained (the door's output for ten jobs); main's calls per job (one job; the 12 of gates 2–3), permission asks, classifier denials, wasted rounds.
