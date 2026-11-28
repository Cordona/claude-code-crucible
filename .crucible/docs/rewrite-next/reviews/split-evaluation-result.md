# Split evaluation: merged result

Two evaluators judged every script against the owner's test, blind to each other (`split-evaluation-brief.md`). Their full reports are in Dev Beta's scratchpad: `split-eval-1.md` and `split-eval-2.md`. Nothing is changed yet.

## Agreed by both

**Split: none.**
- No file holds operations that callers run apart without sharing most of their state.
- The closest call, which both would keep: `git-worktree/scripts/main/worktree-catch-up.sh`, with `--with` and `--abort`. Both halves write the same event and share the merge, record and undo helpers. Split it only if `--abort` grows or gains a second caller.

**Merge back: the worktree setup chain.**
- **What merges:** `setup-copy.sh` and `setup-repoint.sh` into `worktree-setup.sh`. Each has exactly one caller and runs only in sequence. Each re-checks what the step before it handed over (the plan JSON, the copy output, the paths): a private protocol between files.
  - Evaluator 1: medium confidence, about 130 lines of hand-off removed.
  - Evaluator 2: medium-high confidence.
- **`setup-plan.sh` as well:** both see it as possible.
  - Evaluator 1, lower confidence: keeping it separate preserves a read-only plan with its own data file and its own reason to change (adding a technology).
  - Evaluator 2, medium confidence: merging removes the plan-JSON hand-off, about 200 lines in all. `gw_add_problem` and `gw_exit_on_problems` then move from the shared lib into the merged file, since only the setup scripts use them.
- **`worktree-setup.sh` itself stays separate from `worktree-cut.sh`.**

**Keep, high confidence:**
- `mount-apply.sh`: the checks, the apply and the roll-back share about 10 variables, 5 work files and in-process flags, and no caller runs the checks alone.
- `lib/git-worktree.sh` and `lib/mount.sh`: function libraries, not hubs; every helper has two or more users.
- `hold-question-until-card-shown.sh`: hooks on one matcher run in parallel, so the cards can be cleared only after every check. The shape check is already split out.
- `mount-record.sh`, `mount-states.sh`, `mount-paths.sh`, `mount-restore.sh`: 2 to 6 real callers each.
- The four `open-work.sh` scripts, and every other internal script with more than one caller.

**Keep, medium confidence:**
- `tracker-read.sh`: the trackers differ in only 35 to 40 lines, and no caller picks a tracker. Look again at a third tracker.
- `effort-commits.sh`: one caller, but a clean, standalone check. If it gains a caller, it belongs in git-commit.

## Raised by one evaluator only, as notes

- **Rules held in two places:**
  - the mount record's shape, written in `mount-apply.sh` and checked in `mount-record.sh`;
  - the snapshot commit's subject, hard-coded in `effort-commits.sh` and composed in git-commit;
  - the safe-link pattern, copied into `tracker-read.sh` instead of using core's `link-rule.jq`.
- **Five git libraries repeat the same basics:** refusals, effort and repository checks, the work folder. A shared dev-base library would remove that, but it would make each git skill source another skill's files.
- **`check-question-shape.sh` could become a `.jq` lib.**

## Dev Beta's proposal

1. Merge `setup-copy.sh` and `setup-repoint.sh` into `worktree-setup.sh`. Decide `setup-plan.sh` with Fable's view: a read-only plan with its own reason to change, against the plan-JSON hand-off.
2. Give each of the three rules held in two places one home, as with the earlier DRY item.
3. Keep everything else.
4. Leave the shared git library alone: the constitution says components never source across components.
