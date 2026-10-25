# Turning off and uninstalling

What the human removes to turn the inject hook off or to uninstall this flow; read when the human asks how. Step numbers are SKILL.md's.

- **To turn the inject hook off,** the human removes the `PreToolUse` › `Agent` entry running `prepare-agent-prompt.sh` from `settings.json`, then runs `/hooks` or restarts. Step 1 then exits 1, so no dispatch goes out until the entry is back; its Fix item prints the exact entry.
- **To uninstall,** the human removes from `settings.json` the inject hook entry, plus both approval gate entries (the Stop entry running `gate-stop-hook.sh` and the `PreToolUse` › `AskUserQuestion` entry running `gate-question-hook.sh`), and the Crucible-space entry in `permissions.additionalDirectories`, then runs `/hooks` or restarts; step 1 then fails until they are back.
