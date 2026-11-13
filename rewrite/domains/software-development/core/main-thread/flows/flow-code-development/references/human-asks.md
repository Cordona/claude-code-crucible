# The human's asks

The human's asks about shown work, a seat's worktree or its branch. Its terms and steps are SKILL.md's.

- **About a shown report** (its open items, decisions, deviations…): run `jq '.body | <fields>' '<that path>'` for the asked fields of the report event the card's last line names, and relay its output fenced (SKILL.md Always), nothing added.
- **The whole report:** `standard-artifact-handoff`'s line with the event path the card's last line names first; only after a yes, `jq .body '<that path>'`, its output fenced.
- **Either `jq` exits non-zero:** show its stderr and exit code, and the line `The report could not be read.`; nothing else is shown.
- **The card again:** SKILL.md step 4's `card.sh`; for an earlier report, add `--seq <N>`, that report event's seq.
- **A mount, an unmount, or what is mounted:** `procedure-git-worktree`'s `mount.md`.
- **A push** of a worktree's branch, or of every one, whatever the effort's auto-push: `procedure-git-worktree`'s `push.md`.
- **Go on after the git setup stopped:** SKILL.md step 2.
- **A commit or a merge:** per seat, `idle`: show the line `The work is committed in <worktree> (<short sha>); bringing it into your checkout is your step.`; `gave-up` or `working`: show the line `The work in <seat> is not committed; it stays in <worktree>.`
