# Install failures

Steps 1 and 2's results that don't go on. Step numbers are SKILL.md's.

## Step 1: the dependency check

- 1 with stdout starting `Install check:` (jq is missing, so this plain Fix list is the one result `show.sh` does not print and nothing holds owed): show the human its stdout, and stop.
- 1, 4, 129, 130 or 143: stop.
- 5: show the human its stderr, and stop.
- 2, any other exit, or 127 (the script missing): show the reinstall line `flow-code-agent-dispatch is broken: reinstall it under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/, then ask me again.`, word for word without its backticks, and stop.
- 0 from a run with `--line ask_tool_missing` or `--line confirm_hooks_loaded`: stop (SKILL.md Never).

## Step 2: the plugin list

"Show" here means: show the human its stderr and exit code as printed, never its stdout, which is the plugin list for you, not a view for the human:

- A `TRUNCATED:` line on stderr, whatever the exit: show and stop.
- Exit 0 or 1 with a stdout line that isn't a plugin line: show and stop.
- Exit 3: an invalid plugin, named on stderr as `list-plugins.sh: <name>: <reason>`. Show and stop until it is fixed, except on step 2's re-run for a `PLUGIN` problem (steps 8 and 10), as SKILL.md's Always sets.
- Exit 2 or 5: show and stop.
- 127 or any other result: a broken install. Show, then show the reinstall line (Step 1 above), and stop.
