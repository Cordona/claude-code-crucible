# Finding an effort

SKILL.md steps 5–7, which find an effort; read at step 5, when `procedure-resume` runs it. Every command runs `effort.sh` by the full path SKILL.md's Steps set.

5. **Find** the effort. Run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" list`; add `--all` when the effort may be older, or when stderr says `showing 20 of <N>`. When the human gave a full ID, its 4 hex digits or an exact name, run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" path '<that value>'` instead and go to step 7. When the conversation still shows the effort folder's absolute path, run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" path '<the ID in its folder name>'` instead and go to step 7. `list` exits non-zero: show the human its stderr and exit code, and stop.
6. **Match** the human's words to the listed names:
   - One clear match: run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" path '<its id>'`, copying the ID from the list, and go to step 7.
   - Two or more candidates, or none: ask with one AskUserQuestion (SKILL.md Never). Its options: the candidates (with none, the newest listed names), at most 2, the closest match first and marked (Recommended), each showing its `<id>-<name>` and its start date, read from the ID; then "none of these", and last "Stop".
   - On a candidate: run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-effort/scripts/effort.sh" path '<its id>'` and go to step 7.
   - On the first "none of these", or when the list is empty (nothing to offer): ask what earlier work they mean, a full ID, its 4 hex digits or a name, and start step 5 again with their answer.
   - On "Stop", or a second "none of these" or empty list: show the line `No effort is resumed.`, and stop.
7. **Act on `path`'s exit:**
   - 0 with exactly one line, an absolute path under the Crucible space's `efforts/`: keep it (SKILL.md step 5). Any other output: as any other exit.
   - 1 with efforts listed on stderr: ask the human as step 6 sets, those efforts as the candidates. 1 with none: run `list` as step 5 sets, then ask as step 6 sets.
   - Any other exit: show the human the stderr and exit code, and stop.
