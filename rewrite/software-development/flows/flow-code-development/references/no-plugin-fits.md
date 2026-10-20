# No plugin fits

Read in full when `flow-code-development` step 2 routes a `<n>. no plugin fits (<stack>)` hand-back entry, and follow it for that part. "Step N", Terms, Invariants and Checking the reply are those of `flow-code-development`'s `SKILL.md`; "direct step N" is one of the Direct steps below.

For a `BUILD` part handed back as `<n>. no plugin fits (<stack>)`, no installed tech plugin fits its stack. Ask the human whether the main thread writes that part's code itself, as its own approval gate, never bundled into another choice.

## Show the choice

Show it through `procedure-approval-gate`: load it with the Skill tool first, and follow its steps with these inputs.

- **The plan file:** `{"stack", "files", "tasks"}`, written as the gate's step 1.2 sets: the stack from the hand-back line; as `files`, the part's starting points, or the repository root when it has none; as the one task, the part's task as handed in at step 2.
- **The renderer:** `sh "<init scripts>/03-dispatch-plan/render-dispatch-plan.sh" --no-plugin-fits --plan-file <the plan file> --context-file <the context file>`, the context file being the one `flow-agent-initialization` step 3 wrote for this effort. It prints the plan as Markdown, in about 30 ms.
- **On the gate's "now ask":** run `sh "<init scripts>/03-dispatch-plan/render-dispatch-plan.sh" --no-plugin-fits --question --plan-file <the plan file>`, which prints the question as one JSON object, and copy its `header`, `question` and `options` into one AskUserQuestion as they are.
- **The gate can't be loaded, the plan isn't shown, or the question run exits non-zero:** ask nothing, write nothing for that part, and record it, with what was shown, for step 6.

The options:

- **Stop (Recommended):** build the tech plugin first; nothing runs for that part. Record it for step 6.
- **Implement directly,** only on this explicit go: the Direct steps below.

## Direct steps

1. **Get the prompt file:** load `flow-agent-initialization` again with the Skill tool if it isn't in context, and run its step 11 for the part. Keep the `PROMPT:`, `REPORT:` and `LABELS:` lines it hands back, as printed. It stops, or hands back anything else: write nothing for that part, and record it, with what it showed, for step 6.
2. **Read the prompt file** in full with Read before any code, in parts with `offset` and `limit` when it is too large for one Read. Its plugins are your coding rules, its context is your task's context, and its `# Your work` holds your task, `REPO ROOT` and `CONTEXT FILE`.
3. **Take the developer's method:** Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents/code-developer.md`, with the folder expanded to an absolute path. Load `standard-code-development-report` and `procedure-dispatch-context` with the Skill tool. Follow `code-developer.md`'s body as your method, except the rules under each "When being dispatched" subheader, and read the context as `procedure-dispatch-context`'s Steps set. `BUILD` only.
4. **Write the code, then the report:** save the baseline before any code, as step 4 sets, with the prompt file's `REPO ROOT`. Then write the report JSON `standard-code-development-report` sets, with Write, to direct step 1's `REPORT` path. Run `report.sh check` on it as Checking the reply sets, with the prompt file's `REPO ROOT` and `CONTEXT FILE` and your baseline file:
   - exit 3: fix the named fields with Edit and check again, at most twice; then go on, with the last result recorded as `incomplete` for step 6;
   - exit 3 again, naming the same fields as the last check: no progress, so stop fixing and record it as `incomplete` for step 6;
   - exit 4: write the file again and check once more; a second exit 4: record it as `not checked` for step 6;
   - exits 0, 1, 2 and 5: as Checking the reply sets.
5. **Show it** as step 5 sets, with direct step 1's `LABELS:` line, whole, in the labels file, and `--round initial`; never compose the `LABELS:` line yourself.

A failed Read of `code-developer.md` or of the prompt file, or a skill that can't be loaded: tell the human which, show what the read returned, and stop.

After either answer, unless a failed read stopped the run, go back to step 2's next hand-back entry.
