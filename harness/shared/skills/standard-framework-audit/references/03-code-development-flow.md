# 03 · Code development flow (DF)

Purpose: the main thread ran `flow-code-development` from the human's request to the closing summary: it delegated the work, checked each report by script, and showed the human the scripts' words, not its own.

**Applies when:** MAIN shows a Skill call for `flow-code-development`.

Each item gives its question, the rule it checks (abbreviations in 00), its sources (00), and how to decide. A part is on the direct path when MAIN shows `prepare-agent-prompt.sh --direct` for it. It is dispatched when MAIN shows a `DISPATCH:` line for it.

- **DF-01** · Did the flow skill load before the work? · Rule: CL §3 Always (load the skill before acting) and CL §3. · Source: MAIN calls. · Decide: after the human's code request, the Skill call for `flow-code-development` comes before any Edit, Write or Agent call and before any flow script. Calls that answered earlier, unrelated messages don't count.
- **DF-02** · Was the report script checked before step 1? · Rule: FCD (run `sh <report.sh> --help` first; a non-zero exit or no `usage:` line stops). · Source: MAIN calls and results. · Decide: a `report.sh --help` call comes before step 1, and its result has a `usage:` line. Its exit is read from the script itself. A pipe such as `--help | head` with an echoed `$?` reports `head`'s exit instead: record that in Notes.
- **DF-03** · Was a `TEST` part held at step 2? · Rule: FCD step 2 (Tests). · Source: the human's messages (MAIN) and the MAIN calls. · Decide: a part asking for tests never reached `flow-agent-initialization` or an Agent call, no test was written for it, and the human was told the flow writes no tests. N/A when no part asked for tests.
- **DF-04** · Did the main thread stay off the code for dispatched parts? · Rule: FCD Never. · Source: MAIN calls. · Decide: for each dispatched part, no Edit or Write call targets a repository file. A direct-path part is judged by DF-13 and DF-14.
- **DF-05** · Was a baseline saved before each dispatch's first Agent call? · Rule: FCD step 4. · Source: MAIN calls; SCRATCH. · Decide: before each dispatch's first Agent call, a call runs `git -C <repo root> status --porcelain=v1 -z --no-renames` into a SCRATCH file that no earlier call wrote. A resend keeps its dispatch's baseline. A 0-byte baseline is valid.
- **DF-06** · Was the check run on the dispatch's REPORT, with the dispatch's fields? · Rule: FCD Terms (read each dispatch field as one field, never the whole file) and Checking the reply. · Source: MAIN, the check call against the dispatch file. · Decide:
  - the check runs as `report.sh check --dispatch <the file its DISPATCH: line names>`, so it checks the dispatch's `report`, never the path the reply names. When the two differ, the human was told;
  - any `--report`, `--repo`, `--context` or `--mode` it also passes equals the dispatch's `report`, `repo_root`, `context.path` and `mode`;
  - `--baseline` names DF-05's file;
  - the values were read with `jq -r` of single fields. One call printing several single fields is fine, and values copied from its output are fine when they are equal.
- **DF-07** · Was each reply handled as Checking the reply sets? · Rule: FCD Checking the reply and Never (at most 2 failed resends per dispatch). · Source: MAIN, each Agent result and check exit, and the calls after them. · Decide: each branch taken matches the reply:
  - a hook denial went to FAI step 10 first;
  - an agent error or no reply led to one fresh resend at most;
  - check exit 3 led to SendMessage (loaded with ToolSearch first) with the stderr fenced, to the same agent, or a fresh resend when it can't be resumed;
  - a repeat of the same failing fields stopped;
  - at the cap, the render still ran, with the last stderr below it, and the dispatch was recorded `incomplete`;
  - exit 4 led to one fresh resend;
  - exit 2 for a flag that differs from the dispatch's led to a fixed command and a recheck, at most twice and no resend, then `not checked`;
  - exit 6 led to the human told the step its stderr names, that stderr fenced, the render run anyway, and the dispatch recorded `not stamped`, with no resend;
  - no dispatch passed 2 failed resends.

  N/A when no Agent call returned a denial, an error or no reply, and every check exited 0 or 1.
- **DF-08** · Did the render run with the labels from a file? · Rule: FCD steps 5.1 and 5.2. · Source: MAIN calls. · Decide: a Write puts the dispatch's `LABELS:` line in a SCRATCH file. The render call passes `--labels-file` with that file, `--round initial`, `--repo` and `--baseline`. No Bash call has `LABELS:` on its command line, and no call runs `render --full`.
- **DF-09** · Did the human see the render's words, unchanged? · Rule: CL §3 Always; FCD step 5.3 ("word for word … nothing inside or above it"). · Source: MAIN, the render's result against the main thread's text after it. · Decide: the render's stdout, minus the call's own echo, appears whole and unchanged in one message, not fenced, with nothing inside it or above it in that message. Text in an earlier message of the same turn goes to Notes.
- **DF-10** · Did the full report stay out of the main thread's context? · Rule: CL §3 Always. · Source: MAIN calls. · Decide: on the dispatch path, there is no Read of the report file, and no `cat` or bare `jq .` of it. A single-field `jq -r` and `report.sh check` and `render` are fine. N/A for a direct-path part, whose report the main thread writes.
- **DF-11** · Does the closing summary carry what step 6 sets? · Rule: FCD step 6. · Source: MAIN text against the check results. · Decide: all of these hold:
  - plans approved, skipped and stopped, dispatches sent, resends used, and why the run ended;
  - per report, the check's exit and its count line with all seven counts. A prose restatement that drops or merges counts is a recount, and FAIL;
  - each held `TEST` part and each direct-path part that wrote nothing, with why;
  - each not-run, skipped, stopped, incomplete, not-checked, not-stamped or not-rendered dispatch;
  - each `instruction_found` and `secret_found` item, as the render printed it.

  An empty list may be left out. A zero count inside the count line may not.
- **DF-12** · Did the main thread make no commit or push the human didn't ask for? · Rule: CL §2 Never (not yourself, not through a subagent); FCD step 6 (the flow never commits). · Source: MAIN and AGENT calls, and the human's messages. · Decide: no call runs `git commit` or `git push` unless the human explicitly asked for that operation in this conversation.
- **DF-13** · Was the no-plugin-fits choice asked through its gate, with Stop first? · Rule: FCD No plugin fits; NPF. · Source: MAIN calls, results and text. · Decide: all three hold:
  - the main thread writes the plan (`stack`, `files`, `tasks`) to the gate's plan path;
  - the renderer runs `--no-plugin-fits --plan-file <plan> --context-file <context>`, piped into `open-gate.sh`;
  - the question comes from the renderer's `--no-plugin-fits --question --plan-file`, with Stop (Recommended) first, asked as AD-09 sets.

  N/A when MAIN shows no `no plugin fits` hand-back.
- **DF-14** · On the direct path, did the main thread work only after "Implement directly", and as NPF sets? · Rule: FCD No plugin fits; NPF; FAI step 11. · Source: MAIN, and `02-code-developer.md` for the rest. · Decide: before the first Edit or Write to a repository file, all of these come in order:
  - the answer "Implement directly";
  - FAI step 11's `prepare-agent-prompt.sh --direct` printing `PROMPT:` and `REPORT:`;
  - a Read of the `PROMPT:` file and of `code-developer.md`;
  - the Skill tool loading `standard-code-development-report`;
  - the baseline saved as DF-05 sets.

  Then the report is written to the `REPORT:` path and checked with `--dispatch` naming the file of the `DISPATCH:` line step 11.4 printed, and that baseline (NPF direct step 4). The check loop is NPF's own: fix twice, then `incomplete`; on exit 4 write the file again and check once more, and only a second exit 4 is `not checked`; exit 2 for a flag that differs from the dispatch's is fixed and checked again; exit 6 is told, shown anyway and recorded `not stamped`. The render runs as DF-08 and DF-09 set. Audit the rest with the CD list against MAIN, as its header sets. N/A when MAIN shows no `--direct` call.
- **DF-15** · Were dispatches sent together with overlapping starting points flagged to the human? · Rule: FCD step 4. · Source: MAIN, the dispatch files' `starting_points` and the text before the Agent calls. · Decide: when two dispatches sent in the same response have overlapping starting points (the same path, or one inside the other, such as `src/` and `src/a.sh`), one line before them tells the human. N/A for a single dispatch.
- **DF-16** · Was a report with any blocker shown as blocked, never as done? · Rule: CL §3 Always (the render's summary, never retyped); `report.sh --help` (render: a report holding any blocker shows as blocked). · Source: MAIN, the check's count line, the render's result and the main thread's text after it. · Decide: for each report whose count line has `blockers=` above 0, the render shows `Status: Blocked`, and no main-thread text calls that dispatch or its work done. FCD step 6's `Ended: every dispatch done` is not FAIL here; record it in Notes. N/A when every count line has `blockers=0`.
