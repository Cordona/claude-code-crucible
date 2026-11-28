# The permission plan: Fable's confirmation (2026-11-25)

By Crucible Fable Reviwer, for the owner. My confirmation is a review, not a go; the go is the owner's, as Dev Beta relays it.

**What I read:** Dev Beta's three-step plan and the reviewer's new line. I ran nothing.

## Verdict

**Confirmed, with four corrections. None changes the design.**

| # | Correction | Why |
|---|---|---|
| 1 | P17 gets one more row: the hook's deny under a main that accepts edits | otherwise the scope may be void in the mode the owner really uses |
| 2 | If the allow fails, the owner is told before the fallback is built | the fallback lets agents do more than the design the owner accepted |
| 3 | The hook compares real paths | on macOS one folder has two names |
| 4 | The hook checks the agent's type before it looks up a job | it runs on every Write and Edit of every sub-agent |

## 1. The four corrections

1. **One more row in P17.** The plan probes the allow with main in `default`. The owner may run main in accept-edits or bypass mode. Probe that the hook's **deny** still stops a write there, for Write and for Edit. P9 showed it for Bash under bypass; this is the same question for files.
2. **The fallback isn't automatic.** If the allow doesn't hold, Dev Beta's `acceptEdits` design is the next best. It opens `rm`, `mv` and `touch` across the repo and the space, which the owner hasn't weighed. Tell the owner the probe's result first.
3. **Real paths.** The hook should resolve the tree, the report and the written path before comparing them. `/tmp` and `/private/tmp` are the same folder, and a path with `..` can leave the tree while starting inside it.
4. **Cheap first.** Like the Bash hook: no job-taking type, no lookup.

## 2. What I confirm as written

- **The probe's three questions,** and the fallback being Dev Beta's design with its hook.
- **The hook:** in `agent-submission` beside the Bash hook; the scope one word per kind in the agent's own submission file, `report` or `tree`; allow inside, deny outside with a reason that names where to write; main and an agent with no job untouched. "Untouched" means Claude Code's normal permissions apply, so an idle hot agent is asked, not let through.
- **The reviewer gets Write, not Edit.**
- **The `agent-conduct` line,** as I worded it.
- **The order:** the two trials with main started in the repo, then the 33 counted runs.

## 3. The reviewer's line

> Change nothing but your report, and run no command that writes. A reviewer that edits the code is reviewing its own work.

**Approved as it is.** It is true now that the reviewer has a tool to write with, it says only what the agent does, and its second sentence names the failure it prevents.

## 4. The proof cases I'd expect in the runners

- a write inside the tree is allowed, for a kind whose scope is `tree`;
- the same path in main's repo is denied, and the reason names the tree;
- the job's report is allowed, for both scopes;
- a write in the tree is denied for a kind whose scope is `report` (a review, a test plan);
- another effort's tree and another job's report are denied;
- a path that leaves the tree through `..` is denied;
- main's own write, a non-job agent's, and an idle hot agent's pass untouched.

## 5. For the dispatch talk, noted

The owner's model (one job, one tree, one repo; read-only repos added as extra working folders) fits this hook as it stands: the scope limits writes only, and reads follow Claude Code's own permissions.
