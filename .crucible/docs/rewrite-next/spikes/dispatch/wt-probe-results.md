# Worktree-hook probe (route B, "bridge"): results

2026-11-26, Claude Code 2.1.332. Opus main, headless, permission mode default, allow-list by `--settings` (`Agent`, `Bash(git status*)`, `Bash(sh tests/run.sh)`, `Bash(pwd)`); one haiku stand-in per agent. A PreToolUse hook on Agent added `isolation: "worktree"` by `updatedInput`, as the dispatch's prompt swap would. Kit: `wt-kit/` (run.sh, collect.sh, three hook scripts). Evidence: `evidence/wt-probe/<case>/` (state.txt, agent-tools.tsv, hook-counts.txt, logs/hooks/, main-result.txt). Raw transcripts under `evidence/wt-probe/*/transcripts/` stay local. Nothing in new-rewrite/ changed; nothing committed.

**Verdict: route B holds.** The agent starts in our tree, its plain commands match the allow-list, and the tree is left as it was.

## What the docs say

`https://code.claude.com/docs/en/hooks` (WorktreeCreate, WorktreeRemove):
- WorktreeCreate fires for `--worktree`, EnterWorktree, a subagent with `isolation: "worktree"`, a workflow agent, a background session, remote-control worktree mode. It replaces the default `git worktree` behaviour.
- Input: the common fields plus `name`, a slug for the new worktree. No matcher.
- Output: a command hook prints the path as the last non-empty line of stdout. Any non-zero exit, or no path, fails creation. An absolute path with `.`/`..` or one passing through a symlink below the repo root is refused.
- WorktreeRemove: "When a subagent or a workflow agent finishes, Claude Code keeps the worktree your WorktreeCreate hook made for it and doesn't run your WorktreeRemove hook." Claude Code never deletes a branch of a hook-made worktree.

## The questions

| # | Question | Fact | Case |
|---|---|---|---|
| 1 | Does WorktreeCreate fire, for a sub-agent's isolation? | Yes: once per Agent call, with `{session_id, transcript_path, cwd (main's), prompt_id, name: "agent-<agent id>"}` | bridge, parallel |
| 2 | Is the start folder our tree T? | Yes: `pwd` printed T; SubagentStart's `cwd` and every one of the agent's PreToolUse `cwd` were T. T is outside the repo and was accepted | bridge |
| 3 | Do `git status` and `sh tests/run.sh` run plain, no ask? | Yes: both ran with no ask (`On branch job-t1 … clean`, `tests: 1 passed`). The only PermissionRequest was the Write (no write rule in this allow-list, default mode; in the real install the write-scope hook allows writes in the tree) | bridge |
| 4 | Is T intact after the agent ends; does WorktreeRemove fire? | T is there, same HEAD, branch `job-t1`, nothing removed or reset. WorktreeRemove did not fire (as documented) | bridge |
| 5a | No WorktreeCreate hook: what does Claude Code make? | `repo/.claude/worktrees/agent-<agent id>` on a new branch `worktree-agent-<agent id>`; the agent ran there; after it ended (no changes, the write was denied) the folder and branch were gone | native |
| 5b | WorktreeCreate exits non-zero | The agent never starts; main's tool result: `WorktreeCreate hook failed: <command>: <stderr>`. Main relayed the reason | veto |
| bonus | Can the hook tell which agent or job it is for? | The agent: yes, `name` is `agent-<agent id>`, the same id SubagentStart then carries, so the id exists before the agent starts. The job: no, the input has no prompt and no tool_use_id | bridge, parallel |

## Parallel (two Agent calls in one message)

Order, one sample: PreToolUse(call 1) → WorktreeCreate(1) → SubagentStart(1) → PreToolUse(call 2) → WorktreeCreate(2) → SubagentStart(2), each about 50 ms after the one before. Each call's WorktreeCreate ran before the next call's PreToolUse. A queue answer (t1 then t2) put each agent in its own tree.

## What this changes for the design

1. **Starting the agent in its tree works:** the swap adds `isolation: "worktree"`, a WorktreeCreate hook answers with the job's tree. The `cd <tree> && …` forms have no reason to exist.
2. **The hook must find the job's tree itself**, since its input names only the agent. Seen order: each Agent call's PreToolUse is followed by its own WorktreeCreate before the next call's PreToolUse. So the swap step could hand the job to the WorktreeCreate step (a per-session hand-off), which then knows the job, the tree and the agent id at once; that would also put `job.assigned` before the agent's first tool call by construction, not by a race. One sample of the order; not a guarantee.
3. **The same hook covers unasked worktrees:** a WorktreeCreate outside a job (EnterWorktree, `-w`, an agent's own isolation) can be refused (exit 1, reason reaches main) or given a tree by the framework. Policy is the owner's.
4. **No WorktreeRemove work** for job agents: Claude Code keeps the folder and never touches its branch.
5. **Writes still need their rule:** in default mode a Write in the tree asked; the real write-scope hook covers this, the probe didn't install it.
