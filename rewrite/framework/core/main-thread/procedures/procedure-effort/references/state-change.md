# Changing an effort's state

SKILL.md step 9, which pauses, completes, drops or reopens an effort; read at step 9, when the human asks for one of those, or answers an offer (SKILL.md step 10) with Pause, Complete or Drop.

`<effort.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh"` and `<render-effort-state.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/render-effort-state.sh"`, their `--help` run as SKILL.md's Steps set. `<crucible.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crucible/scripts/crucible.sh"` and `<grill.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-grill/scripts/grill.sh"`: run `<crucible.sh> --help` and `<grill.sh> list --help` once each, before their first use in a session, and not again in that session unless their contract is no longer in context (after a compaction). A non-zero exit, or no `usage:` line: show the stderr and exit code, change nothing, and stop.

9.1 **Which effort.**
- The human names none and the conversation shows the effort folder's absolute path: use that path.
- Otherwise: Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/find-effort.md`, follow its steps 5–7 and keep the path they find; its reopen question doesn't run from here. Its stop changes nothing: stop here too.

9.2 **Open work,** for complete or drop only; pause and reopen go to step 9.3.
- Look in the folder: run `<crucible.sh> find --effort '<folder>' --kind dispatches`, then `<crucible.sh> find --effort '<folder>' --kind reports/development`, then `<grill.sh> list --effort '<folder>'`, each a Bash call of its own. Read each report the dispatches point to.
- Open work is exactly: each dispatched part with no report, or whose report has no `dispatch` key (never checked); and each grill `list` shows `open`. Nothing else counts: not uncommitted edits, not a report's items for the human, not parts never dispatched. The rule is the same for complete and drop.
- None: step 9.3.
- Some: Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/open-work-question.json`, fill `<items>` with a short list of the open items in your words, naming each task or topic, never a path, and `<move>` with "Complete" or "Drop", and pass its `questions` to one AskUserQuestion.
- `open-work-question.json` can't be read or isn't one JSON object with a `questions` array: show the line `The open-work question could not be read. Nothing was changed.`, and stop.
- "Keep it open" or a typed answer: nothing is written; answer a typed reply, and stop. "Complete anyway" or "Drop anyway": step 9.3.
- A `find` or `list` that exits non-zero, or a Read of a report that fails: ask the same question, `<items>` saying which read failed, since you can't tell whether work is open.

9.3 **Change it:** run `<effort.sh> <pause|complete|drop|reopen> --effort '<folder>'`, and act on its exit:
- 0 with a `STATE:` and an `ITEM:` line: step 9.4. Without them: as any other exit.
- 6: run it once more; a second 6: show the stderr, and stop: nothing was written.
- 7: relay the stderr as printed: nothing was written. Stop.
- Any other exit: show the stdout, stderr and exit code, and stop.

9.4 **Show it:**
- **Paused, completed or dropped:** run `<render-effort-state.sh> changed --effort '<folder>'` and relay its stdout (SKILL.md Always); on a non-zero exit, as SKILL.md Always sets. No work of that effort goes on (SKILL.md Never). A new request goes by CLAUDE.md §4.
- **Reopened, on the human's ask:** load `procedure-resume`; the conversation shows the path.
