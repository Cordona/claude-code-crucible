# Changing an effort's state

SKILL.md step 9: pause, complete, drop or reopen an effort. Read it when the human asks for one of those, or answers an offer (SKILL.md step 10) with Pause, Complete or Drop.

`<effort.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh"` and `<render-effort-state.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/render-effort-state.sh"`, their `--help` run as SKILL.md's Steps set. `<crucible.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crucible/scripts/crucible.sh"` and `<grill.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-grill/scripts/grill.sh"`: run `<crucible.sh> --help` and `<grill.sh> list --help` once each, before their first use in a session. Run them again in that session only when their contract is no longer in context (after a compaction). A non-zero exit, or no `usage:` line: show the stderr and exit code, change nothing, and stop.

9.1 **Which effort.**
- The human names none and the conversation shows the effort folder's absolute path: use that path.
- Otherwise: Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/find-effort.md`, follow its steps 5–7 and keep the path they find; its reopen question doesn't run from here. If it stops, stop here too, changing nothing.

9.2 **Open work,** for complete or drop only; pause and reopen go to step 9.3.
- Look in the folder: no `<folder>/slots.json` means no seat holds work. Otherwise run `jq -r '.slots[] | select(.status == "working" or .status == "gave-up" or has("awaiting_round")) | [.slot, .status, .dispatch] | @tsv' '<folder>/slots.json'`, then `<grill.sh> list --effort '<folder>'`, each a Bash call of its own. For each seat it prints, find its dispatch file with `<crucible.sh> path '<its dispatch>'`, then take its task with `jq -r '.task' '<that path>'`, each a Bash call of its own. Never Read a whole report or `slots.json`.
- Open work is exactly: each seat `working`, `gave-up` or awaiting a fix round; and each grill `list` shows `open`. Nothing else counts: not an `open` seat, not an `idle` one, not a report's items for the human, not parts never dispatched.
- None: step 9.3.
- Some: Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/open-work-question.json`. Fill `<items>` with a short list of the open items in your words: name each task or topic and, for a seat, whether it is still working, gave up or awaits a round; never a path. Fill `<move>` with "Complete" or "Drop". Pass its `questions` to one AskUserQuestion.
- `open-work-question.json` can't be read or isn't one JSON object with a `questions` array: show the line `The open-work question could not be read. Nothing was changed.`, and stop.
- "Keep it open" or a typed answer: nothing is written; answer a typed reply, and stop. "Complete anyway" or "Drop anyway": step 9.3.
- A `jq` or `path` that exits non-zero, a task read that prints an empty value or `null`, or a `list` that exits non-zero: ask the same question, `<items>` saying which read failed, since you can't tell whether work is open.

9.3 **Change it:** run `<effort.sh> <pause|complete|drop|reopen> --effort '<folder>'`, and act on its exit:
- 0 with a `STATE:` and an `ITEM:` line: step 9.4. Without them: as any other exit.
- 6: run it once more; a second 6: show the stderr, and stop: nothing was written.
- 7: relay the stderr as printed: nothing was written. Stop.
- Any other exit: show the stdout, stderr and exit code, and stop.

9.4 **Show it:**
- **Paused, completed or dropped:** run `<render-effort-state.sh> changed --effort '<folder>'` and relay its stdout (SKILL.md Always); on a non-zero exit, as SKILL.md Always sets. No work of that effort goes on. A new request goes by CLAUDE.md §4.
- **Reopened, on the human's ask:** load `procedure-resume`; the conversation shows the path.
