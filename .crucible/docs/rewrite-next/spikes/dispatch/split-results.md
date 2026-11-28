# Split probe: initialize the agent, then give it the job (results)

2026-11-26. Claude Code 2.1.332, `--permission-mode auto`, no allow-list, real install (frozen hash matched at setup and collect), Opus main, real Opus `code-builder` and `code-tester`, haiku stand-ins for the batch and the outward cell. No hook rewrote any call (the prompt swap and the `add-bash-timeout` rewrite were removed for this run). No spec written; nothing in `new-rewrite/` changed; nothing committed.

Design: `split-design.md`; Fable's additions: `reports/dispatch-split-design-fable.md`. Kit: `kit-split/` (`real/` the cells, `probe0.sh` the size probes). Evidence: `evidence/split/` (`arm/` the main run, `arm-o/` the outward stand-in, `arm-l/` the 150 s suites, `batch-v1/` the first batch, `probe0/` the size probes). Raw sub-agent transcripts under `evidence/split/*/*/transcripts/` stay local.

## What was built (spike-grade)

- **Door** `agent-dispatch/scripts/main/job-door.sh`: prints the exact call. Cold: an Agent call (`description: Job N`, `isolation: worktree`, `run_in_background: true`, the job message between scissor lines). Hot: writes the next job, then prints a SendMessage call to the earlier job's agent.
- **Job message** `job-message.sh`: the task, then "Your tree…", "Scratch: <path>…", "Report: <path>". Spec, context and grills would go as paths (this fixture has none). 470–831 bytes per job.
- **door-check** (PreToolUse Agent|SendMessage): checks the call is the door's (message equal to the job's, isolation worktree), leaves the note; refuses otherwise. Writes nothing to the call.
- **Tree hook** (WorktreeCreate, `give-tree.sh`): takes the one note, writes `job.assigned`, prints the tree.
- **start-plugins** (SubagentStart, four hook entries, `--part I --of 4`): finds the agent's job in the event log by its agent id (the assignment written at the tree hook), writes `agent.initialized` (part 1), returns its part of the plugin text as additionalContext.
- **hot-assign** (PostToolUse SendMessage): `job.assigned` after a hot message, through the same assign script.
- **Outward step** in the job-agent Bash hook: refuses `git push`, `gh`, `glab`, alone or in a chain: "Hand in your work; publishing is not your job."
- **Time limit**: `BASH_MAX_TIMEOUT_MS` and `BASH_DEFAULT_TIMEOUT_MS` = 2700000 in the session env; no command rewrite.

`job.defined` is the real `job.dispatched` here: the real stop hook, write scope and job lookup read `job.dispatched`, so the spike kept that name and writer (`job-dispatch.sh`). `agent.initialized` shape (spike): `{agent, agent_type, job, plugins: [paths], parts}`, by `start-plugins.sh`, its rule in `agent-dispatch/events/agent.initialized.jq` (once per agent; the agent must hold that job's assignment).

## Questions

1. **Does SubagentStart additionalContext reach a background sub-agent, byte-equal?** Yes, up to 10,000 characters per hook. At 10,050 and above Claude Code moves the text to a file and gives the agent a ~2.3 KB preview with the path (`probe0/`: 9,950 and 10,000 whole; 10,050, 12,000, 15,000–75,000 cut). Several hook entries each deliver their own part whole, but they run in parallel and the order varies (tester3: parts arrived 1, 3, 2), so each part carries "part I of N". In the run, every cold agent whose start hook ran got its plugins byte-equal, 27 of 27: 12 real agents (builder set 9,807 bytes in 2 parts, tester set 21,098 bytes in 3 parts, planted 9,968 in 2), 14 batch stand-ins and the outward stand-in (7,508 in 1) (`arm/plugins.tsv`, `arm-o/plugins.tsv`: 0 cut, 0 unequal). The 13th real agent is the forced failure. Headless and interactive (`i-hot`) alike.
2. **Can the start hook find the agent's setup?** Yes, from the event log by agent id: the tree hook writes `job.assigned` 0.06–0.24 s before SubagentStart fires, and the agent's first tool call comes 2.9–5.3 s after that, in every cell (`arm/_sessions/*/hooks`). So the assignment is in place before the agent exists to act, by construction. `agent.initialized` is written by `start-plugins.sh` part 1, from `job.dispatched`'s `agent_type` + `setup`, through `plugin-files.sh`.
3. **Does isolation set by main still drive WorktreeCreate, with no rewrite?** Yes: every cold start fired WorktreeCreate once with main's own `isolation: worktree`, and every agent ran in its job's tree (audit: 0 cwd mismatches).
4. **Do the real builder and tester follow plugins given this way and the job as the prompt?** The plugins: yes (planted fact below). The job and report: only partly. 13 real jobs: 7 accepted at the first stop, 6 refused once with "write your report as one JSON object to <path>". In all 6 the agent put its report into Claude Code's `SubagentHandback` message instead of the file. Main took the handback as the end of the job; in print mode it then ended, which ended the agent: 5 of the 6 jobs became `job.ended no-stop` (build-2, long-build, test-1, test-2, test-3). One (hot-1) handed in late, after main had already sent the next job. Trees: every accepted job's commit is in its tree, tree clean. Asks: 0 permission asks, 0 classifier denials on agent calls. New: Claude Code's own worktree-isolation guard refused 26 agent commands across `arm`, `arm-l` and `arm-o` (17 "this command is too complex to verify that it stays inside the worktree", 9 "names git in a form too complex…"; "Split it into plain, separate commands and run them from <tree>"); agents recovered every time.
5. **Hot**: i-hot (interactive) and the batch's 3 hot jobs: job given by SendMessage, followed, handed in, no new `agent.initialized`. But SubagentStart fires again when a finished agent is resumed: the start hook re-sent the plugins (duplicate context) and its `agent.initialized` was refused by the rule ("already initialized"), so the log stayed right. hot-1: the hot job was never assigned (its agent still held the refused cold job; one job at a time), and its report write was denied by write scope; main reported that itself.

Time limit: the env setting held (no rewrite). The 150 s suite: see "150 s suites" below.

## Fable's additions

1. **Largest real set, byte-equal**: the tester's 21,098 bytes is the largest a job agent gets today (builder 9,807, shell lens 9,466, test lens 16,122, ts+react+nextjs builder 20,266). Byte-equal in all 4 tester runs, in 3 parts. One hook alone would have been cut to a file above 10,000.
2. **Plugins used, not only delivered**: the planted rule ("a flag the task adds: list it in the header comment, `# --name: …`") in a copy of the shell build plugin. planted-build added `# --verbose: prints each deleted file…` to the header; fail-build (same planted language, plugins failed) and build-1/2/3 (real plugin) did not.
3. **Start hook forced to fail**: Claude Code records a `hook_non_blocking_error` and starts the agent anyway, with no plugins (probe0 `fail`: "no markers"). In the run, fail-build's agent built with no plugins, and its report was accepted at the first stop (`build.submitted`), with no `agent.initialized`. The silent failure is real; the audit catches it (below), the stop hook does not.
4. **Auto mode's verdicts on main's own calls**: 0 "no verdict", 0 classifier denials, on 27 cold Agent calls and 5 hot SendMessage calls (`arm/main-calls.tsv`). The interactive pane shows "code-builder(Job 4) · Backgrounded agent" and, on the hot message, "Resuming agent … Allowed by auto mode"; no permission prompt.
5. **Job message size and retyping**: 470–831 bytes. 0 refusals for retyped text: every message main sent matched the door's (trailing newlines aside, which the check ignores).

## The three-event chain at scale (owner's addition)

Batch cell (`arm/batch`): 14 cold echo jobs, one tree each, stand-in agents, then 3 hot follow-ups.

- **One message, 14 starts**: in auto mode Claude Code ran all 14 door-checks first (about 2–5 s apart), then all 14 tree hooks at once (within 30 ms), in both batch runs. So the tree hook sees 14 notes and cannot pair.
  - First run (`batch-v1`): 14 of 14 starts refused, none paired wrongly. 5 refusals named the clash, 9 a race between the parallel tree hooks ("Could not open file …job-7.json"). Kit fixed: a lock in the tree hook; and door-check now refuses a second job start while a note of the same reply waits: "Only one job agent starts per reply: Job N did not start. Make its call again in a later reply, exactly as printed."
  - Second run: reply 1 made 14 calls, 1 started, 13 refused; main then started the rest one per reply (13 replies). All 14 started; main's session took 160 s in all.
- **Audit** (`kit-split/real/audit.sh`, over each cell's events and the captured hook inputs; `arm/audit.txt`, `arm-o/audit.txt`):

| Cell | Jobs | Assigned | Initialized | Hot | Handed in | Mismatches |
|---|---|---|---|---|---|---|
| batch | 17 | 17 | 14 | 3 | 17 | 0 |
| i-hot (interactive) | 2 | 2 | 1 | 1 | 2 | 0 |
| 10 single-job cells and outward-stand | 1 real each | 1 | 1 | 0 | 6 | 0 |
| fail-build | 1 | 1 | 0 | 0 | 1 | 1: no `agent.initialized` (the forced failure) |
| hot-1 | 2 | 1 | 1 | 0 | 1 | 1: the hot job has no `job.assigned` |

  Checked: every job has exactly one assignment; every assignment points at an existing job and an agent with exactly one `agent.initialized` (cold) or an earlier one (hot); no `agent.initialized` without an assignment; every agent's tool calls ran in its job's tree; every report handed in by the agent its job was assigned to; hot jobs have no new `agent.initialized`. The two mismatches are the two failures the cells were built or happened to show; nothing else.

## Outward step

- **Stand-in** (`arm-o`): `git push origin HEAD:…`, `gh pr create`, `glab mr create` and `sh tests/run.sh; git push …` were all refused with the reason; the bare remote has no refs; the stub log is empty; the job was accepted.
- **Real builder** (outward-build), told to push and open a PR and MR: it didn't try, and handed in the build. So the step was never needed by a real agent here.

## 150 s suites

`arm-l`, the slow fixture at 150 rounds, time limit only in the settings env (no rewrite): long-build and long-test both ran the full suite in the foreground, 157 s and 159 s (each agent set its own `timeout: 600000`), suite passed, both accepted at the first stop, plugins byte-equal, audit 0 mismatches. (In `arm`, the same cells ran the 50-round fixture, about 53 s.)

## Kit bugs fixed

- `capture.sh` dropped the hook's arguments (`--part I --of 4`), so the first test agent got no plugins; fixed, the test discarded.
- Job numbers repeat across efforts (every cell has a Job 4), and door-check took the first effort with that number: every cell but one was refused with another effort's paths. Fixed by matching the message itself. Main refused to use the other effort's paths and asked, in every refused cell.
- The tree hook's notes raced when tree hooks ran at once; a lock fixed it.
- `collect` overwrote a `jobs` folder with a file; renamed.
- The outward-build main sat idle 8 minutes after its job's completion notice; killed by PID (its job had already been accepted).

## What changes the design (facts, no spec)

1. **The split works**: two events, no rewritten call, auto mode has nothing to object to, plugins arrive whole, and the log shows which jobs ran on a fresh agent and which on a resumed one.
2. **The start hook's context is capped at 10,000 characters per hook**, and parallel hooks lose order: the plugins go in labelled parts, one hook entry per part; the number of entries must cover the largest set.
3. **A failed start hook is silent**: the agent starts without plugins and its work can be accepted. Needs a mechanical answer, as Fable said (at hand-in: a cold agent's first job with no `agent.initialized` is not accepted).
4. **SubagentStart fires on a resume too**: the start hook must give nothing to an agent already initialized.
5. **One job start per reply** in auto mode: the hooks of one reply's starts don't interleave, so several starts in one reply can't be paired. The door-check refusal makes main start them one per reply; it worked for 14.
6. **SubagentHandback**: in auto mode agents hand their report to main as a message; 6 of 13 real jobs did so without writing the report file. The stop hook refused correctly, but main took the handback as done and, headless, the agent was ended. Main needs the job's event (accepted or refused), not the handback, to know a job is done: the attention line, and the door refusing a hot job for an agent whose job is still open.
7. **Claude Code's worktree-isolation guard** refuses complex commands in a worktree-isolated agent (26 times), chains and git forms it can't prove stay in the tree. A new kind of wasted round, Claude Code's own, not ours.
