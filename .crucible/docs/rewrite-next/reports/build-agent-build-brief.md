# Build brief: the build agent's submission (scripts only)

For the shell-script developer, from Dev Beta. The owner approved the spec and the tree. Build the scripts, and prove by running them that they do what the spec promises. **No prose:** no SKILL.md, no agent `.md`.

## What to read first

1. **The spec:** `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/reports/build-agent.md`. It covers the reports, the validation rules with their exact repair lines, the hook's order, the working commit and its trailers, the two events, iteration and fix round, and the cases.
2. **The tree:** `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/reports/build-agent-tree.md`.
   - **One change the owner made after it:** there is no `submit-agent-work/` subfolder. The five step scripts sit directly in `hooks/subagent-stop/`, beside `submit-agent-work.sh`.
   - Only `submit-agent-work.sh` is registered in `matchers.json`.
3. **Fable's reasons:** `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/reports/tree-fable.md`.

## The conventions to follow (read the existing code, copy its patterns)

- **The repo:** `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/`. Model your scripts on its components:
  - `framework/core/main-thread/crucible-events/`, the event writer `scripts/internal/event-write.sh` and its libs, including `sha256.sh` and `beside.sh`;
  - `domains/software-development/core/main-thread/git-identity/` and `git-commit/`, for how a component calls the event writer and its own rule;
  - `framework/core/main-thread/crucible-gate/hooks/`, for how a hook reads its JSON input, finds the effort, holds or lets through, and prints;
  - `framework/core/install/install-entries.sh`.
- **The script style:**
  - POSIX `sh`, `set -eu`, jq 1.6 or later;
  - every script has `--help` with the same contract blocks as the existing ones (usage, Reads, Writes, Stdout, Exit);
  - `refuse()`, and exit codes as the neighbours use them.
- **Placement:**
  - jq files that are not event rules go in `scripts/lib/`;
  - event rules go in `<component>/events/<type>.jq`, one per type, pinning `by` to the one script allowed to write it;
  - hook-only scripts go in the hook folder, shared scripts in `scripts/`.
- **No process traces** (task IDs, decision IDs, history notes) in any file you write, and nothing about the lab or the spike.
- Never search from `/`; scope every find and grep to the repo.

## What to build

Everything in the tree, with these specifics:
- **`agent-jobs` (`domains/software-development/core/main-thread/`):**
  - `events/job.dispatched.jq`, `job.ended.jq`, and a minimal `job.assigned.jq` (body `{job, agent, name}`), so that a job can be found by the agent id. The proof writes these three through the real event writer, with `--by` naming the pinned writer.
  - `scripts/internal/job-of.sh` and `events-view.sh`, `scripts/lib/iteration.jq` and `pinned-report.jq`.
  - `scripts/main/` stays empty.
  - The `job.dispatched` body holds only what this build reads: kind (`build` or `fix`), the agent type, the tree (the job's worktree), the report path, the chosen findings for a fix (with any the human sent back after a decline), known failures, iteration, fix round, and the setup (language, framework, standards, model optional).
- **`agents/agent-submission/`:**
  - the wrapper and its five steps in `hooks/subagent-stop/`, plus `hooks/matchers.json`;
  - `scripts/internal/recover-submission.sh` and `scripts/lib/trailers.sh`.
- **`agents/code-builder/`:**
  - `build-submission.json` and `fix-submission.json`;
  - `events/build.submitted.jq` and `fix.submitted.jq`;
  - the two validation scripts, and `lib/report-validation.sh` (the shared shell, sourced by both), `build-report.jq`, and `fix-report.jq` (which includes `build-report.jq` and replaces the unchanged-tree rule).
- **The installer (`framework/core/install/install-entries.sh`):**
  - folders directly in an `agents/` folder are components, linked like `main-thread/` ones;
  - `subagent-stop` maps to `SubagentStop`;
  - two components with one name are refused.

  Check that `install-check.sh` still agrees, and run both scripts before and after.
- **The working commit** goes through `git-commit`'s main script.
  - It is unsigned. If git-commit can't make an unsigned commit today, add the smallest option it needs, and say so.
  - The trailers come in this order: `Effort`, `Job: <seq> <name>`, `Iteration`, `Fix-Round` (fix only), then the setup lines (`Language`, `Framework`, `Standards`, `Model` if present).
- **The events' bodies** are printed in this order: job, iteration, fix_round, agent, report {path, sha256}, commit. Absent fields stay absent.

## The behaviour to prove

Write `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/evidence/build-agent/run.sh`. It does three things:
- sets up a scratch git repo with a worktree, a scratch effort, and a scratch `CLAUDE_CONFIG_DIR` (never `~/.claude`, never a real key; working commits are unsigned);
- writes the jobs from `fixtures/` through the real event writer;
- runs each case of `build-agent.md` §8 by feeding the real `submit-agent-work.sh` the hook JSON that Claude Code gives a SubagentStop.

For each case, save to `evidence/build-agent/<case>/`:
- `report.json`;
- `hook-output.txt`, the hook's stdout and exit code;
- `event.json`, the event written, or none;
- `commit.txt`, `git log -1 --format=%B` plus `git show --stat`, or none.

**The cases:**
1. A clean build (iteration 1), then a second build on the same tree (iteration 2).
2. A build with a known failure: no blocker needed.
3. A blocked build: no commit, and the event has no `commit` field.
4. A refused report showing its repair lines, then a second refusal ending the job with `job.ended` (gave-up).
5. A fix with done, partly and declined: `fix.submitted`, with its iteration and fix round 1, and the trailers.
6. A fix that declines a finding the human sent back: refused with the spec's line; then the same fix with a `cannot` blocker, accepted.
7. A report changed after submission: `events-view.sh` refuses it, with the line the human would see.
8. A working commit whose event is missing: `recover-submission.sh` writes the event from the `Job` trailer.

Also check every repair line in `build-agent.md` §4 at least once: a small table-driven check is fine. Make `run.sh` exit non-zero if any expectation fails.

## Done means

- `run.sh` passes from a clean start, twice in a row;
- every script answers `--help`;
- `install-entries.sh` lists the new components and the SubagentStop hook;
- the existing tests or checks in new-rewrite you touched still pass.

**Report back:**
- the files you created or changed;
- anything in the spec you couldn't build as written, and why;
- the `run.sh` output.

Don't commit anything.
