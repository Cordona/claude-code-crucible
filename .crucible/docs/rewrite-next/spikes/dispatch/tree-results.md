# Tree run: the job chain on the framework's real git-worktree

2026-11-26, Claude Code 2.1.332. One interactive session in auto mode: Opus main, haiku stand-in agents. Owner's go, Fable-confirmed, from the coordinator's brief.

- **Kit:** `kit-tree/`, the stress kit adapted.
- **Sandbox:** `/Users/Shared/crucible-sandbox/tree`.
- **Effort:** real, through `effort-start.sh`, with its identity set through git-identity's real scripts and the gate's real hooks. Scratch keys only: its own HOME, git config and ssh agent.
- **Cutting:** `kit-tree/cut.sh JOB` sources the scratch identity and calls the framework's `worktree-cut.sh`, unmodified, with the job's own `from` (each word one `--from`). The tool writes `worktree.cut`.

## Shapes as run

- **Job tree:** `{"cut": {"from": "<the tool's string>"}}` or `{"use": <seq of a worktree.cut>}`. The job scripts compare `from` as a string and never parse it. The tool records a repeated from as one space-joined string, for example `"worktree:t5 worktree:t6"`, so the job carries the same string.
- **`job.assigned.tree`:** the `worktree.cut` seq. `worktree.cut` has no job field.
- **The door** takes `--tree SEQ` for a cut job. It checks that the cut's `from` equals the job's, and that no other cut job is assigned that tree, or holds it in a printed start (added during the run, below).
- **The iteration rule's key** is the `worktree.cut` seq. A build on `use T` must be one more than the builds already on T.
- **A review's range** comes from the tree's head at resolve: base from `worktree.cut.base`, head from `git rev-parse HEAD` in the tree.
- **Checking a `from` before the card:** `worktree-cut.sh` has no check-only mode, so resolve can't do it. A bad `from` first surfaces at the cut (cell e).

## Cells

| Cell | Result |
|---|---|
| (a) ref cut, chain, two-tree merge | **Pass** |
| (b) two jobs, same `from`, one proposal | **Pass**, after a door fix |
| (c) a reviewer and a replacement on `use` | **Pass** |
| (d) a second build on a tree via `use` | **Pass** |
| (e) a `from` the tool refuses | **Recorded** (no pass line) |

**(a) Ref cut, chain, two-tree merge.**
- **Ref:** jobs 5, 6 and 7 were cut from `ref:main` (trees t5, t6, t7).
- **Chain:** job 21 was cut from `worktree:t5`. Its tree t21 holds t5's a.txt plus its own c.txt.
- **Merge:** job 22 was cut from `worktree:t5 worktree:t6`. Its tree t22 holds a.txt, b.txt and its own d.txt. The tool made a signed merge base, "crucible(base): join the tips of the trees a tree is cut from", recorded as `worktree.cut` 26 with `signed: true`.
- **Conflict** (no pass line): job 23 asked for `worktree:t5 worktree:t7`, which both changed a.txt. The tool refused at the cut with exit 2: "the tips of t5 t7 conflict in a.txt; nothing was cut". No tree, branch or event was left behind.

**(b) Two jobs with the same `from` in one proposal.** The three builds from `ref:main` each got their own tree (`worktree.cut` 8, 9 and 10, assigned once each).
- **Planted:** `door.sh 6 --tree 8` (job 5's tree). It was accepted at first, because job 5 hadn't started yet and the door only looked at assignments.
- **Fix:** the door now also refuses a tree that another cut job holds in a printed start. Rechecked once job 5 was assigned: "worktree.cut 8 is already another job's cut".
- **Not rerun live:** the held-but-unassigned case itself.
- Independently, the `job.assigned` rule refuses a second cut job on one tree, so a race would have been refused at the start.
- **Planted, wrong tree:** `door.sh 21 --tree 26`: "worktree.cut 26 is from "worktree:t5 worktree:t6"; job 21 asks "worktree:t5"".

**(c) A reviewer and a replacement on `use`.**
- **Reviewer:** job 36 (use 8) stood in t5.
- **Replacement:** job 38 (use 9) was a planted dying agent. It was ended dead and replaced by job 48, a copy with `{"replaces": 38}` and the same `use` 9, which stood in t6.

**(d) A second build on a tree via `use`.**
- Job 37 (build, use 8) was resolved and accepted as iteration 2, after job 5's build on tree 8.
- A dry define of a third build on tree 8 claiming iteration 1 was refused: "iteration must be 3, the next build on tree 8".
- Jobs 36 and 37 stood in t5 at the same time. The review's range was resolved before job 37 committed: head b67af01, now 656b8d5. That's expected, since the range is fixed at resolve.

**(e) A `from` the tool refuses** (recorded).
- **The jobs:** job 24 (`ref:nosuch`) and job 23 (the conflict).
- **Where it surfaced:** the card showed both, since resolve can't check. Both were defined. Both refusals came at the cut step, exit 2, with the reason on stderr: "--from ref: nosuch is no commit of …/repo" and the conflict line above. `cut.sh` passed each refusal on and logged it.
- **The log afterwards:** `job.defined` with no `worktree.cut` and no `job.assigned`. Main then dropped both with `end-job.sh` and a note each, so the log is complete again.
- **Cost:** a refused `from` costs a defined job and a drop. A check-only mode in `worktree-cut.sh` would move the refusal before the card.

## Audit (log alone, then transcripts, then the tool)

- 0 problems:
  - every `job.assigned.tree` resolves to a `worktree.cut`;
  - a `use` job's tree equals its `use`;
  - a cut job's tree has the job's `from`;
  - no `worktree.cut` is two cut jobs' tree;
  - no `worktree.cut` has a job field;
  - every defined job ended: 9 handed in, 1 dead and replaced, 2 dropped.
- 9 agents; all 9 stood in their job's tree (pwd), and the vanishing agent ran no command by design.
- The `worktree-cut.sh` used is the framework's own file through the installed-layout link: sha256 equal, unmodified against HEAD.

## Kit changes and deviations

1. **The card's tree line used the old field** and showed a blank "cut from". It was fixed and re-shown before the human answered.
2. **The door's held-tree gap** (cell b), fixed and then scoped to cut jobs only: a `use` tree is shared by design.
3. **`gate.answered` is core's**, and its rule takes no `shown` field. The kit's human approval is its own `proposal.approved` `{path, sha256}`. The shape change to core's event is still open.
4. **The framework's `agent-jobs` component was left out** of the installed skills folder, because its job rules would collide with the kit's. The kit's rules run as a component `kit-jobs`, through the framework's own `event-write.sh` and `events-read.sh`: one writer, one lock, one seq.
5. **Main misread a `--tree` it passed for `use` jobs** (gate C): it thought the held-tree check had failed, when that check correctly doesn't apply to shared trees. The door's printed refusal or acceptance should say which rule applied.

## Evidence

- Effort: `/Users/Shared/crucible-sandbox/tree/space/efforts/*-tree-run/events/` (51 events) and its `worktrees/`.
- Logs: `logs/refusals.log`, `logs/kit-bugs`, `logs/cut-*.err`.
- The audit: `python3 -I kit-tree/audit.py`.
- Transcripts stay local.
