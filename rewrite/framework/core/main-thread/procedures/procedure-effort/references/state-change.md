# Changing an effort's state

SKILL.md step 9: pause, complete, drop or reopen an effort. Read when step 9's trigger holds (SKILL.md step 9).

`<effort.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh"` and `<render-effort-state.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/render-effort-state.sh"`, their `--help` run as SKILL.md's Steps set; showing a line is as they set too. `<seats.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-git-worktree/scripts/seats/seats.sh"` and `<grill.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-grill/scripts/grill.sh"`: run `<seats.sh> --help` and `<grill.sh> list --help` once each, before its first use in a session. Run one again in that session only when its contract is no longer in context (after a compaction). A non-zero exit, or no `usage:` line: that read failed (step 9.2's last bullet).

9.1 **Which effort.**
- The human names none and the conversation shows the effort folder's absolute path: use that path.
- Otherwise: Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/find-effort.md`, follow its steps 5–7 and keep the path they find; its reopen question doesn't run from here. If it stops, stop here too, changing nothing.

9.2 **Open work,** for complete or drop only; pause and reopen go to step 9.3.
- Run `<seats.sh> busy --effort '<folder>'`, then `<grill.sh> list --effort '<folder>'`, each a Bash call of its own. Never Read a report, and never read the effort's `events/` yourself.
- Open work is exactly: when `busy` exits 8, each line it prints (seat, status); `busy` exiting 0 means no seat has open work. And each `GRILL:` line whose second field, the fields split at each `·` with a space either side, is `open` (not the third, its `open <n>` count). Nothing else counts: not an `ended` grill, not a report's items for the human, not parts never dispatched.
- None: step 9.3.
- Some: Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/open-work-question.json`. Fill `<items>` with a short list of the open items in your words: name each seat or topic and, for a seat, whether it is still working or gave up; never a path. Good: "seat build-agent-alpha still working; grill auth-scope open". Bad: "some things are unfinished" (names nothing). Fill `<move>` with "Complete" or "Drop". Pass its `questions` to one AskUserQuestion.
- `open-work-question.json` can't be read or isn't one JSON object with a `questions` array: show the line `open_work_question_not_read`, with `--effort '<folder>'`, and stop.
- "Keep it open (Recommended)" or a typed answer: nothing is written; answer a typed reply, and stop.
- "Complete anyway" or "Drop anyway": step 9.3.
- `<seats.sh> busy` exiting other than 0 or 8, `<grill.sh> list` exiting non-zero, or either `--help` failing (above): ask the same question, `<items>` saying which read failed, since you can't tell whether work is open.

9.3 **Change it:** run `<effort.sh> <pause|complete|drop|reopen> --effort '<folder>'`, and act on its exit:
- 0 with a `STATE:` and an `EVENT:` line: show the human any `effort.sh:` stderr line as printed (such as a harvest that did not start), then step 9.4. Without them: as any other exit.
- 6: run it once more; a second 6: show the stderr, and stop: the state did not change (each timed-out lock wait leaves a fault in `events/faults/`).
- 7: relay the stderr as printed: the state did not change (a move refused under the events lock leaves only a fault in `events/faults/`). Stop.
- Any other exit: show the stdout, stderr and exit code, and stop.

9.4 **Show it:**
- **Every change:** run `<render-effort-state.sh> changed --effort '<folder>'`; on a non-zero exit, as SKILL.md Always sets.
- **Its work** stays held until a reopen (SKILL.md Never).
- **A new request** goes by CLAUDE.md §4.
- **Reopened, on the human's ask:** load `procedure-resume`; the conversation shows the path.
