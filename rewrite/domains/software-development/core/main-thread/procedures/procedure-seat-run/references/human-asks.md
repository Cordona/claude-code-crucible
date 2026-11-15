# The human's asks

The human's asks about shown work or its commit. Its terms and steps are SKILL.md's.

- **About a shown report** (its open items, decisions, deviations…): for the asked fields of the report event the card's last line names, run `text=$(jq '.body | <fields>' '<that path>') && <show.sh> line --views <seat views> --name report_data --effort '<effort folder>' --arg text "$text"`, so the line `report_data` fences what `jq` read (SKILL.md Always).
- **The whole report:** `standard-artifact-handoff`'s line `show_text_offer` first, its `path` the event path the card's last line names; only after a yes, the same run with `jq .body '<that path>'`.
- **Either run exits non-zero:** show its stderr and exit code, and the line `report_not_read`; nothing else is shown.
- **The card again:** SKILL.md Results' `<card.sh>`; for an earlier report, add `--seq <N>`, that report event's seq.
- **A commit or a merge:** per seat, `idle`: show the line `work_committed`, with `--arg worktree '<worktree>'` and `--arg sha '<short sha>'`; `gave-up` or `working`: show the line `work_not_committed`, with `--arg seat '<seat>'` and `--arg worktree '<worktree>'`.
