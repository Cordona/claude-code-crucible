---
name: procedure-seat-run
description: "Seat scripts run by path, the skill never loaded: an effort's seat records (seat events, dispatches, report drafts), the done test and the agent hooks. Use when a step runs one of them, or the agent hooks are installed. `seats.sh` appends seat events; the stop hook writes events, commits, report-draft renames and, with auto-push on, pushes. Needs jq. Not for worktrees, merges, mounts or asked pushes (`procedure-git-worktree`), or dispatches (`flow-code-agent-dispatch`)."
user-invocable: false
---

# Procedure: Seat run

A seat's records are `seat.*` events in the effort's `events/`, which only scripts append: this skill's `seats.sh` and its hooks through it (the stop hook its `seat.conflicts.resolved` directly), and `procedure-git-worktree`'s scripts (`push.sh` its `seat.pushed`); read the seats only through `seats.sh list --effort` (the list as JSON) or `seats.sh get`. A seat's dispatches are `dispatch.made` events, its developer's report is in the effort's `drafts/agents/<seat>/` and its hook faults are events, so the worktree holds no seat folder, and the stop hook's commit takes every change in the worktree. The stop hook writes `stop.*`, `fault.raised`, `build.committed` and `seat.conflicts.resolved` events, and the rename and removal of the report draft in `drafts/agents/<seat>/`. The seat's worktree, branch and base are `procedure-git-worktree`'s.

## Scripts

Under `<seat scripts>`, `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-seat-run/scripts`, one folder per job. `flow-code-development` runs `seats/seat-name.sh`, `seats/seats.sh` and `seats/iteration.sh` itself; each one's `--help` is its full contract; the lines `seats.sh find --card` and `iteration.sh --checked` print (`report_gave_up`, `run_not_committed`, `checked_earlier`) are in `views/lines.jq`; that flow shows the first two itself on a resume and after `block-relay-hook.sh`'s gave-up wake. The hooks in `hooks/` (`seat-bind-hook.sh`, `report-commit-hook.sh`, `block-relay-hook.sh`) run from Claude Code's `settings.json`; each `--help` is its contract. `flow-code-agent-dispatch` step 1 checks their entries, and its `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/flow-code-agent-dispatch/references/turn-off-and-uninstall.md` removes them.

## Dependencies

- **Skills,** under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/`, none loaded: `human-view` (its `show.sh` prints the lines in `views/`); `procedure-git-worktree`, whose commit and push scripts the stop hook runs by path; `procedure-git-setup`, whose `settings.sh` the stop hook runs by path; `crucible`, whose `events.sh` the hooks, `seats.sh` and `iteration.sh` run by path, and whose `lib/prune.jq` `seats.sh` loads. Outside that folder: `standard-code-development-report`, whose report checker the stop hook runs from the software-development tree (`report-commit-hook.sh`'s `CHECKER_DIR`).
- **Commands:** jq 1.6+ (the system's package manager); each script's `--help` names the rest of its needs.
