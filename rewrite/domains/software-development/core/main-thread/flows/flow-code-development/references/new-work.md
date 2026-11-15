# New work on a seat

New work the human asks for on a seat that exists, after its last work was shown; a change to work already shown stays Changes. Its terms are SKILL.md's, and Changes' steps are those SKILL.md's Changes sends you to read with this file.

Copy steps 1–4 into the todo list and tick each.

1. **Decide with the human** (SKILL.md Always), from their ask, asking what it leaves open:
   - **Where it starts:** moved to another commit main picks (a branch it cut, the remote main, a release branch, another MR), or where the seat is now.
   - **The agent:** the hot agent goes on when its plugins fit the new work; a fresh agent when the work needs other plugins or the agent is spent. Plugins come from each plan, not the seat.
2. **The move,** when the work starts elsewhere: by `procedure-git-worktree`'s `move-and-catch-up.md` (Move), the branch or ref passed by its name; load that skill with the Skill tool if it isn't in context. A refusal: send nothing (SKILL.md Always, Send nowhere).
3. **The hot agent:** run `sh "<seat scripts>/seats/seats.sh" task --effort '<effort folder>' --seat '<seat>' --task '<task>'`, `<task>` the task in the human's words as one value, single-quoted, each `'` as `'\''` (CLAUDE.md's "Quote values for scripts"). Exit 0: go on; a non-zero exit: send nothing (SKILL.md Always, Send nowhere). Then send the task as Changes step 3 sends a change, the task in place of the change, its `REPORT:` line included, and the line `task_sent` shown in place of `change_sent`; its result: SKILL.md step 4, then SKILL.md step 5 for this work alone.
4. **A fresh agent:** run `sh "<seat scripts>/seats/seats.sh" handover --effort '<effort folder>' --seat '<seat>'`; a non-zero exit: send nothing (SKILL.md Always, Send nowhere). Then take the work through SKILL.md step 2.5 as a new plan on that seat, shown at the dispatch-plan gate with its plugins. Then SKILL.md steps 3–4.
