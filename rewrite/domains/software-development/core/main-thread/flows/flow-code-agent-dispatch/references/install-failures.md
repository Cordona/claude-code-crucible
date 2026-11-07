# Install failures

Steps 1 and 2's results that don't go on. Step numbers are SKILL.md's.

## Step 1: the dependency check

- 1, 129, 130 or 143: stop.
- 2, any other exit, or 127 (the script missing): show the reinstall line `flow-code-agent-dispatch is broken: reinstall it under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/, then ask me again.`, word for word without its backticks and as a message of its own, and stop.
- AskUserQuestion not in your tool list: show the line `AskUserQuestion is not available, so no plan can be approved and nothing is dispatched.`, as the reinstall line is shown, and stop (SKILL.md Never).
- After the human adds or changes a hook entry, show the line `Confirm under /hooks that the hook entries step 1 lists are loaded, then ask me again.`, as the reinstall line is shown, and stop (SKILL.md Never).

## Step 2: the plugin list

"Show" here means: show the human its stderr and exit code as printed, never its stdout, which is the plugin list for you, not a view for the human:

- A `TRUNCATED:` line on stderr, whatever the exit: show and stop.
- Exit 0 or 1 with a stdout line that isn't a plugin line: show and stop.
- Exit 3: an invalid plugin, named on stderr as `list-plugins.sh: <name>: <reason>`. Show and stop until it is fixed, except on step 2's re-run for a `PLUGIN` problem (steps 8 and 10), as SKILL.md's Always sets.
- Exit 2 or 5: show and stop.
- 127 or any other result: a broken install. Show, then show the reinstall line (Step 1 above) in a message of its own, and stop.
