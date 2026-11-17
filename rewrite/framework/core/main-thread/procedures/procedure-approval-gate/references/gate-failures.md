# Gate failures

Step numbers are SKILL.md's.

## Step 3: no hook message, and the turn ended

On the human's next message, run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/flow-code-agent-dispatch/scripts/dependencies/validate-dependencies.sh"`. Whatever its exit, show the line `relay_not_confirmed`, then the script's stdout as printed, since human-view's Stop hook, which would hold its card owed, may be what failed. Ask nothing, and tell the gate's procedure the plan was not shown. SKILL.md's Never sets when a new gate may open.

`<views>` is `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-approval-gate/views"`; its lines go without `--effort`. human-view's Stop hook may be what failed here, and so may jq, which `show.sh` needs: when `show.sh` exits non-zero for `relay_not_confirmed`, show its stderr, then `**Blocked · the plan's relay could not be confirmed:** run /hooks or restart Claude Code, then ask me to show the plan again`, without its backticks; for any other line, show its stderr.

- **`flow-code-agent-dispatch` missing** (the script exits 127): in place of the script's stdout, show the line `hooks_not_checked`, and stop as this section sets.

## Step 4: a blocked AskUserQuestion

- Denied with a reason starting `procedure-approval-gate:` that says the gate is pending (its plan not yet relayed): relay first (step 2; in a later turn, step 1 first), end the turn, then ask on "now ask".
- Denied with a reason starting `procedure-approval-gate:` that says the gate record could not be saved: show the human the reason, fix what it names, if anything, and ask the question once more. When it says to open the gate again, start again at step 1 instead. A second such deny: ask nothing, and tell the gate's procedure the plan was not shown.
- Blocked with any other reason, such as an internal error or jq missing (the question hook failing closed): show the human the reason, ask nothing, and tell the gate's procedure the plan was not shown.

## Gotchas

- **The hooks guarantee nothing when they don't run:** a Stop hook timeout or fault lets the turn end with no message (step 3), and a question hook timeout lets the question through.
- **A question blocked with jq missing:** install jq, then open the gate again.
- **To turn the gate off,** the human removes the three gate entries from `settings.json` (the `PreToolUse` › `AskUserQuestion` entry running `gate-question-hook.sh`, and the `PostToolUse` › `AskUserQuestion` and `UserPromptSubmit` entries running `gate-answer-hook.sh`), then runs `/hooks` or restarts. human-view's card Stop entry, running `show-stop-hook.sh`, stays: every card needs it. `flow-code-agent-dispatch`'s install check then fails until they are back; its Fix items print the exact entries.
