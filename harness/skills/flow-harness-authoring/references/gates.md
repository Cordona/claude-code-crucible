# Gate hooks

Read when a gate's hooks did not run (`SKILL.md` Gates, step 3), or when the owner asks how to register or turn off the gate hooks.

## The two entries

Both go in the owner's `$HOME/.claude/settings.json` under `hooks`; only the owner adds or removes them:

```json
"Stop": [
  { "matcher": "*", "hooks": [ { "type": "command", "command": "sh \"$HOME/.claude/skills/flow-harness-authoring/scripts/gate-stop-hook.sh\"" } ] }
],
"PreToolUse": [
  { "matcher": "AskUserQuestion", "hooks": [ { "type": "command", "command": "sh \"$HOME/.claude/skills/flow-harness-authoring/scripts/gate-question-hook.sh\"" } ] }
]
```

## Gotchas

- **Hooks not yet active:** a new entry takes effect after `/hooks` or a restart.
- **The hooks guarantee nothing when they don't run:** a Stop hook fault lets the turn end with no message, and a question hook timeout lets the question through. The relay is what shows the view, so always relay it.
- **jq missing:** the question is blocked while this session's gate is pending; install jq 1.6+, then open the gate again.
- **To turn the gate hooks off,** the owner removes both entries, then runs `/hooks` or restarts. Gates then fall back to asking at the owner's next message.
