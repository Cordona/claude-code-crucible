# No plugin fits

Read in full when `flow-code-development` step 2 routes a `<n>. no plugin fits (<stack>)` hand-back entry, and follow it for that part. "Step N", Terms, Invariants and Checking the reply are those of `flow-code-development`'s `SKILL.md`; "direct step N" is one of the Direct steps below.

For a `BUILD` part handed back as `<n>. no plugin fits (<stack>)`, no installed tech plugin fits its stack. Ask the human whether the main thread writes that part's code itself, as its own approval gate, never bundled into another choice.

## Show the choice

Show it through `procedure-approval-gate`: load it with the Skill tool first, and follow its steps with these inputs.

- **The renderer's contract:** run `sh "<init scripts>/dispatch-plan/render-dispatch-plan.sh" --help` once, before its first use in a session, and not again in that session unless its contract is no longer in context (after a compaction); every other call runs only the command its step names.
- **The plan file:** the `--no-plugin-fits` input that `render-dispatch-plan.sh --help` sets, written as the gate's step 1.2 sets: the stack from the hand-back line; as files, the part's starting points, or the repository root when it has none; as the one task, the part's task as handed in at step 2.
- **The renderer:** `sh "<init scripts>/dispatch-plan/render-dispatch-plan.sh" --no-plugin-fits --plan-file <the plan file> --context-file <the context file>`, the context file being the effort's latest context version, as `procedure-context` hands it over (step 1).
- **On the gate's "now ask":** run `sh "<init scripts>/dispatch-plan/render-dispatch-plan.sh" --no-plugin-fits --question --plan-file <the plan file>`, which prints the question as one JSON object, and copy its `header`, `question` and `options` into one AskUserQuestion as they are.
- **The gate can't be loaded, the plan isn't shown, or the question run exits non-zero or prints anything but one JSON object with `header`, `question` and `options`:** ask nothing, write nothing for that part, and record it, with what was shown, for step 6.

The options:

- **Stop (Recommended):** build the tech plugin first; nothing runs for that part. Record it for step 6.
- **Implement directly,** only on this explicit go: the Direct steps below.
- **A typed answer:** neither option. Show it back to the human, write nothing for that part, and record it as `stopped: typed answer` for step 6.

## Direct steps

Copy direct steps 1–5 into the todo list and tick each as it completes; note each recheck in its item (`recheck 1 of 2`).

1. **Get the prompt file:** load `flow-agent-initialization` again with the Skill tool if it isn't in context, and run its step 11 for the part, before any code is written: its step 11.5 writes the part's baseline. Keep the `PROMPT:`, `REPORT:`, `DISPATCH:` and `LABELS:` lines it hands back, as printed. It stops, or hands back anything else: write nothing for that part, and record it, with what it showed, for step 6.
2. **Read the prompt file** in full with Read before any code, in parts with `offset` and `limit` when it is too large for one Read. Its plugins are your coding rules, its context is your task's context, its `# Handling your context` is how you read, weigh and report on that context, and its `# Your work` holds your task, `REPO ROOT` and `CONTEXT FILE`.
3. **Take the developer's method:** Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents/code-developer.md`, with the folder expanded to an absolute path. Load `standard-code-development-report` with the Skill tool. Follow `code-developer.md`'s body as your method, except the rules under each "When being dispatched" subheader, and handle the context as the prompt file's `# Handling your context` sets. `BUILD` only.
4. **Write the code, then the report:** write the report JSON `standard-code-development-report` sets, with Write, to direct step 1's `REPORT` path. Run `report.sh check` on it, with, as `--dispatch`, the file direct step 1's `DISPATCH:` line names, and act on every exit as Checking the reply sets, but:
   - exit 3: fix the named fields yourself with Edit and check again, at most twice; then, or when the same fields fail again, act as at the cap;
   - exit 4: write the file again and check once more; a second exit 4: record it as `not checked` for step 6.
5. **Show it** as step 5 sets, with direct step 1's `LABELS:` line, whole, in the labels file, and `--round initial`; never compose the `LABELS:` line yourself.

A failed Read of `code-developer.md` or of the prompt file, or a skill that can't be loaded: tell the human which, show what the read returned, and stop.

After any answer, unless a failed read stopped the run, go back to step 2's next hand-back entry.
