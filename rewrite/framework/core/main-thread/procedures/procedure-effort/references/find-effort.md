# Finding an effort

SKILL.md steps 5–7, which find an effort; read at step 5, when `procedure-resume` runs it, or when SKILL.md step 9 or 11 needs the effort. Every command runs the scripts by the full path SKILL.md's Steps set.

5. **Find** the effort. Run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" list`; add `--all` when the effort may be older, or when stderr says `showing 20 of <N>`. When the human gave a full ID, its 4 hex digits or an exact name, run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" path '<that value>'` instead and go to step 7. When the conversation still shows the effort folder's absolute path, run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" path '<the ID in its folder name>'` instead and go to step 7. `list` exits non-zero: show the human its stderr and exit code, and stop.
6. **Match** the human's words to the listed names:
   - One clear match: run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" path '<its id>'`, copying the ID from the list, and go to step 7.
   - Two or more candidates, or none: ask with one AskUserQuestion (SKILL.md Never). Its options: the candidates (with none, the newest listed names), at most 2, the closest match first and marked (Recommended), each labelled `<name> · <start date> · <state>`, the date read from the ID and the state from `list`'s second field (it may read `unknown`); when two listed efforts share a name, add the ID's 4 hex digits after the name, `<name> (<hex>)`; then "none of these", and last "Stop".
   - On a candidate: run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" path '<its id>'` and go to step 7.
   - On the first "none of these", or when the list is empty (nothing to offer): ask what earlier work they mean, a full ID, its 4 hex digits or a name, and start step 5 again with their answer.
   - On "Stop", or a second "none of these" or empty list: show the line `No effort is resumed.`, and stop.
7. **Act on `path`'s exit:**
   - 0 with exactly one line, an absolute path under the Crucible space's `efforts/`: keep it (SKILL.md step 5). Any other output: as any other exit.
   - 1 with efforts listed on stderr: ask the human as step 6 sets, those efforts as the candidates, each one's state read from the second field of its line in `list --all`, run as step 5 sets.
   - 1 with none listed: run `list` as step 5 sets, then ask as step 6 sets.
   - Any other exit: show the human the stderr and exit code, and stop.
   - **A second effort, first:** when `procedure-resume` runs this and this conversation already works on a different effort (SKILL.md Always), warn before the state check: Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/references/resume-here-question.json`, fill `<open>` with those efforts' names, each as inline code, comma-separated, never the one being resumed, and `<next>` with the resumed effort's name as inline code, and pass its `questions` to one AskUserQuestion.
   - **On "Open a new session (Recommended)":** show the line `` `<name>` was not resumed here. Open a new session or run /clear, then ask to continue it. ``, and stop.
   - **On "Go on here":** the state check below.
   - **A typed answer:** a reply: answer it, and stop; nothing resumes.
   - **The question file can't be read:** show the line `The resume question could not be read. Nothing is resumed here.`, and stop.
   - **Then the kept path's state:** run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" state --effort '<that path>'`.
   - **`STATE: open`:** keep the path.
   - **Any other state, when `procedure-resume` runs this:** ask with one AskUserQuestion, header "Reopen", question "`<name>` is <state>. Reopen it?", options "Reopen it (Recommended)", "it opens again and the work resumes", and "Leave it <state>", "nothing resumes".
   - **Any other state, from SKILL.md step 9 or 11:** keep the path, with no reopen question; that step decides.
   - **On "Reopen it (Recommended)":** run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" reopen --effort '<that path>'`; exit 0 with a `STATE: open` line: keep the path. Any other exit or output of `reopen`: show the stderr and exit code, and stop.
   - **On "Leave it <state>"** or a typed answer: show the line `` `<name>` stays <state>. ``, and stop.
   - `state` exits non-zero, or prints no `STATE:` line: show the stderr and exit code, and stop.
