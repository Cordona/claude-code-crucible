# Reply failures: hook denials, agent errors, failing checks and resends

What to do when a reply is a hook error, an agent error, no reply or any other reply, when `report.sh check` exits anything but 0 or 1, or before any resend; read from SKILL.md's Checking the reply. Its terms (`<REPORT>`, `<report.sh>`), steps, Never and Always are SKILL.md's.

## A hook denial

`PreToolUse:Agent hook error:` with a reason starting `flow-agent-initialization:`: once SKILL.md's Checking the reply has taken the dispatch to `flow-agent-initialization` step 10, act on what it hands back:
- a new `DISPATCH:` line: resend with it (Resending); a new `LABELS:` line with it replaces the old one at render, and a new `TITLE:` line the old one in the working line (step 4);
- `stopped`, `stopped: no installed plugin for <name>` or `stopped: plugin files changed for <name>`: record the dispatch as `stopped` for step 6; no resend;
- `stopped: hook failed`, any other result, or the flow can't be reloaded: record the dispatch as `not run` for step 6; no resend.

## An agent error, no reply, or any other reply

- **An agent error, or no reply:** a fresh resend (below), once only for this dispatch. A second agent error or no reply: record the dispatch as `not run` for step 6, and show the human the last reply.
- **Any other reply:** record the dispatch as `not run` for step 6.

## `report.sh check` exits 3, 4, 2, 6, 5 or any other

- **3, invalid:** stderr names each failing field.
  - Before each such send, copy `<REPORT>` to a new file in the session scratchpad, named `<report file name>_previous` (`cp <REPORT> <that file>`), so the report as it was before the fix stays on disk; a failed copy: send nothing, and act as at the cap.
  - Load SendMessage with ToolSearch (it is a deferred tool), then send those lines, fenced (source `report.sh check`), to the same agent, so it keeps its context, fixes the named fields with Edit and replies `REPORT: <path>` again; then check again.
  - Each such send is one resend, inside the cap.
  - The agent can't be resumed: a fresh resend.
  - A check whose stderr names the same failing fields as the last one made no progress: stop resending, and act as at the cap.
  - At the cap, render anyway, with `--dispatch <dispatch file>` added to step 5.2's command, since the report is unstamped; show its stdout as step 5 sets, and record the dispatch as `incomplete` for step 6.
- **4, not a report:** one fresh resend for this dispatch. A second exit 4: record it as `not run` for step 6.
- **2, usage:** a stderr starting `report.sh: dispatch:`: the dispatch file failed its check, which no rerun fixes; stop for that dispatch, show the line `This dispatch stops: its dispatch file failed its check.`, then its stderr fenced (source `report.sh check`) as a message of its own, record it as `not checked` for step 6, and never rerun the check. Otherwise the command is wrong, a flag that differs from the dispatch's included: fix it and run the check again, at most twice, then record the dispatch as `not checked` for step 6; these reruns are no resend.
- **6, valid but not stamped:** the report is unchanged. Send its stderr, which names the step that failed, fenced (source `report.sh check`) as a message of its own, then render anyway (step 5, with `--dispatch <dispatch file>` added, since the report is unstamped), and record the dispatch as `not stamped` for step 6; no resend.
- **5, or any other exit:** show the human its stderr as is, and the report's path marked `unchecked (report.sh could not run: <stderr's first line>)`, never its content. Only when the script itself can't run, also show the install line for `standard-code-development-report`. Record the dispatch as `not checked` for step 6; no resend.

## A fresh resend

Call Agent again, as step 4 sets, with the same `DISPATCH:` line. A hook denial goes to `flow-agent-initialization` step 10, as A hook denial (above) sets. A fresh resend carries no check lines: the task is fixed in the dispatch file.

## Resending

Resend from step 4, unless the fix changes the approved plan (SKILL.md Always); then route it: a change to `TEST` goes to Tests; a change to the context is a new version through `procedure-context`, and what it does to the plan is `flow-agent-initialization`'s; any other change (the language, a framework, the other plugins) goes back through `flow-agent-initialization` as a new hand-in, its steps in order. The resend cap (Never) applies to every resend.
