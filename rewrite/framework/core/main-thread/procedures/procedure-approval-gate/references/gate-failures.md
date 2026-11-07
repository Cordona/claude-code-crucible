# Gate failures

Step numbers are SKILL.md's.

## Step 3: no hook message, and the turn ended

On the human's next message, run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/flow-code-agent-dispatch/scripts/dependencies/validate-dependencies.sh"` (its `--help` first, once per session, as for every script). Whatever its exit, send the fixed line below as one message, word for word without its backticks. Send the script's stdout as printed (its pass line, or its view with every Fix or Warnings item) as the next message. Put nothing else in either. Ask nothing, and tell the gate's procedure the plan was not shown. SKILL.md's Never sets when a new gate may open.

`**Blocked · the plan's relay could not be confirmed:** run /hooks or restart Claude Code, then ask me to show the plan again`

- **`flow-code-agent-dispatch` missing** (the script exits 127): in place of the script's stdout, send the line `The gate's hooks could not be checked: flow-code-agent-dispatch is not installed.`, word for word without its backticks, and stop as this section sets.

## Step 4: a blocked AskUserQuestion

- Denied with a reason starting `procedure-approval-gate:` that says the gate is pending (its plan not yet relayed): relay first (step 2; in a later turn, step 1 first), end the turn, then ask on "now ask".
- Denied with a reason starting `procedure-approval-gate:` that says the gate record could not be saved: show the human the reason, fix what it names, if anything, and ask the question once more. When it says to open the gate again, start again at step 1 instead. A second such deny: ask nothing, and tell the gate's procedure the plan was not shown.
- Blocked with any other reason, such as an internal error or jq missing (the question hook failing closed): show the human the reason, ask nothing, and tell the gate's procedure the plan was not shown.

## Gotchas

- **The hooks guarantee nothing when they don't run:** a Stop hook timeout or fault lets the turn end with no message (step 3), and a question hook timeout lets the question through. The relay itself is what shows the plan, so always relay.
- **A question blocked with jq missing:** install jq, then open the gate again.
- **To turn the gate off,** the human removes both gate entries from `settings.json` (the Stop entry running `gate-stop-hook.sh` and the `PreToolUse` › `AskUserQuestion` entry running `gate-question-hook.sh`), then runs `/hooks` or restarts. `flow-code-agent-dispatch`'s install check then fails until they are back; its Fix items print the exact entries.
