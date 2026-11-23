# Split evaluation: brief

An evaluation, not a refactor. No file is changed; the result is a verdict per script, for the owner to approve before any change.

## The test (the owner's)

Splitting is good when a file is a hub: it holds distinct operations in one file. Splitting is bad when it is unnatural. Splitting for its own sake hurts high cohesion, and it hurts main and human maintainers: every split adds a file, a help and a contract that someone must understand.

**Split** when the parts:
- are distinct operations a caller (main, another script or a hook) would run on their own, or a hub dispatching to them;
- each have a contract you can state in one line;
- change for different reasons, such as two trackers or two git operations.

**Don't split**, and **merge back** an existing split, when:
- the parts only make sense in sequence, for one caller;
- the split makes the files pass a lot of internal state between them, which is a private protocol with new ways to fail;
- the only reason is length. A long file with one job is fine.

Note that `scripts/internal/` already keeps a job script out of main's context. So a needless split now costs maintainers, not main, and the bar for keeping one is cohesion, not context.

## Scope

Every script and lib in `new-rewrite/`, but chiefly:
- **The large files Fable ranked:**
  - `git-mount/scripts/main/mount-apply.sh`: read-only checks, then the apply, the record and the roll-back;
  - `git-worktree/scripts/internal/setup-plan.sh`;
  - `git-worktree/scripts/lib/git-worktree.sh`;
  - `trackers/scripts/main/tracker-read.sh`;
  - `crucible-gate/hooks/pre-tool-use/hold-question-until-card-shown.sh`, which Fable called the one justified exception.
- **Splits already made, to judge whether each should stand or be merged back:**
  - `git-worktree`: `worktree-setup.sh` with `setup-plan.sh`, `setup-copy.sh` and `setup-repoint.sh`;
  - `git-mount`: `mount-record.sh`, `mount-restore.sh`, `mount-states.sh`, `mount-paths.sh` and `effort-commits.sh`, cut out of the old `lib/mount.sh`;
  - any other internal script with exactly one caller.
- **Anything else you find** that is a hub, or an unnatural split.

## Per script, report

- **The verdict:** split, keep, or merge back (and into what).
- **The operations it holds,** each in one line, and who calls each one.
- **The evidence:**
  - callers, found by grep;
  - shared state between the parts;
  - whether a part is ever run alone;
  - for a merge, how many lines of hand-off would go away.
- **Confidence:** high, medium or low.

Size alone is never a finding.
