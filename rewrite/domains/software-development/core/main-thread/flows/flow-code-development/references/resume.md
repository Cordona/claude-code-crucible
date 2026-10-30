# Resume: the effort's parts after a break

What to do with each part of the effort after a compaction, an interruption or a new session; read from SKILL.md's Resume, before any other step. Its terms (`<REPORT>`, `<report.sh>`, `<crucible.sh>`), steps, Never and Always are SKILL.md's.

## The context and the parts

- **The context:** load `procedure-context` with the Skill tool, with the effort folder's absolute path, and act on what it hands back as step 1 sets; its Resume finds the latest context version (its `CONTEXT` state), and every part below uses that version. With no version yet (its `CONTEXT-NONE` state), discovery is still open: it says where things stand and asks the human where they left off, as it sets, and nothing below runs until it hands a version over.
- **Find the dispatched parts:** run `sh <crucible.sh> find --effort '<the effort folder>' --kind dispatches` (its `--help` first, once per session, and again only when its contract is no longer in context), which prints the effort's dispatch files, newest first, and read each one's task with `jq -r '.task' <dispatch file>`. Take the dispatched parts from those tasks, never from a task you write from memory. When `find` prints at least one dispatch file and the conversation doesn't show which are this session's, ask as SKILL.md's Never sets, with `multiSelect: true`: the options are the newest dispatch files' tasks, at most 3, newest first, each with its date, read from its file name's leading Crucible ID (`<YYYYMMDDTHHMMSS>-<hex>`, the time it was made), then "Stop", and the human may also name a part with no dispatch yet. "Stop", picked alone or with others, ends the flow as SKILL.md's Never sets, with nothing more shown. Two dispatches with one task: the newest stands for the part. A replacing dispatch (SKILL.md Terms) stands for the part. Its `<REPORT>` (Terms) is a file in the effort's `reports/development/`.

## One state per part

A part whose report check is still in context goes on by SKILL.md's steps. Every other part takes the first state below that fits, the iteration states (An iteration) first when a baseline names an iteration. Only the run that was in flight when the session broke (a report never checked, Ended unstamped below) is rendered; a finished part's report is never rendered again unasked (SKILL.md Always). When `find` prints no dispatch file and no part is NOT-DISPATCHED, go to step 2, splitting the request as the latest context version's notes hold it. A report shown here ends its message; while parts remain, take the next one in the same turn, as step 5.3 sets.

**Ended unstamped:** a non-empty report with no stamp whose check the conversation or its todo item holds (recorded `incomplete`, `not stamped` or `not checked`) has ended: show the line as **REPORT-CHECKED** sets, its state `unstamped`, and never check or render it again. When neither holds its check (a new session), ask the human once, one AskUserQuestion with `multiSelect: true` naming each such report by its part's task, which were already shown to them; never guess. A report picked has ended, as above; one not picked takes its state below.

- **NOT-DISPATCHED** — a part the conversation still shows, or one the human names when asked, with no dispatch file among those `find` printed: take it back through step 2 with the latest context version, so each `BUILD` part goes through `flow-agent-initialization` again.
- **MAY-RUN** — after a compaction in the same session, its Agent call shows no reply yet, so it may still be running in the background: wait for its reply as SKILL.md's Never sets, and check it as SKILL.md's Checking the reply sets. An agent error or no reply is `not run`, and a `report.sh check` exit 3 or 4 is handled as **REPORT-UNCHECKED** sets. Take only parts whose call has ended into the states below; when you can't tell, ask as SKILL.md's Never sets.
- **REPORT-CHECKED** — `<REPORT>` holds a report with a stamp (`jq -r '.dispatch // empty' <REPORT>` prints an ID): it passed its check already, so never check or render it again: show the line `Checked earlier, <state>: <task> · <path>`, `<state>` `done` or `blocked` by SKILL.md Terms' done test and `<path>` the report's, whole. Render it (step 5) only when the human asks.
- **REPORT-UNCHECKED** — `<REPORT>` holds a report with no stamp that hasn't ended (Ended unstamped): run `report.sh check` on it and act on its exit as SKILL.md's Checking the reply sets, except exits 3 and 4, which go as this bullet sets. Exit 3: render and show it as step 5 sets for an unstamped report, and record it as `incomplete`. Exit 4: take it as **NO-REPORT**.
- **NO-REPORT** — `<REPORT>` is empty or missing: the developer never reported. When a /clear or an interruption came after the dispatch and no reply was seen, ask whether its agent may still run, as SKILL.md's Never sets. On "it may still run", re-plan nothing for that part and record it as `not checked` for step 6. Otherwise re-plan the part through step 2, its task copied from the dispatch file, and hand that dispatch file in with it (step 2).

## An iteration

A part's iterations are found through its dispatch's baselines (SKILL.md Terms), each naming its report, N and baseline, in a new session too. The part takes one state, for its latest run alone: a state above when no baseline names an iteration, otherwise its highest N's state below, its report taken as Ended unstamped (above) sets when that fits; an earlier report is never shown again (SKILL.md Always).

- **ITERATION-CHECKED** — the iteration's report is stamped: show the line as **REPORT-CHECKED** sets; render it (SKILL.md Iterations step 6, with that baseline) only when the human asks.
- **ITERATION-UNCHECKED** — non-empty, no stamp, not ended (Ended unstamped): run the iteration's check against its baseline (SKILL.md Iterations step 5), and act on it as it sets, except exits 3 and 4, so a session that doesn't hold the agent ID never sends to it. Exit 3: render and show it as Iterations step 6 sets, and record the iteration as `incomplete`. Exit 4: take it as **ITERATION-SENT**.
- **ITERATION-SENT** — empty: ask whether its agent may still run, as **NO-REPORT** sets. On "it may still run", record the iteration as `not checked` for step 6. Otherwise ask the human before the part goes the unreachable way (SKILL.md Iterations), saying its change comes from the change list the conversation holds, or from their words when it holds none; on a no, re-plan nothing.

The agent ID no longer in context or in its todo item: the next change goes the unreachable way (SKILL.md Iterations).

## Showing and failing

- **When its `LABELS:` line is no longer in context:** show it without step 5.1 and `--labels-file`, never with a line you composed.
- **`find` or a `jq` read fails, or prints `null`:** an empty output of SKILL.md Terms' baseline lookup is no iteration, never a failure. Otherwise show the human its output, and record the part as `not checked` for step 6.
