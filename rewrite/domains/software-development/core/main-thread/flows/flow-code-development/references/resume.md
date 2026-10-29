# Resume: the effort's parts after a break

What to do with each part of the effort after a compaction, an interruption or a new session; read from SKILL.md's Resume, before any other step. Its terms (`<REPORT>`, `<report.sh>`, `<crucible.sh>`), steps, Never and Always are SKILL.md's.

## The context and the parts

- **The context:** load `procedure-context` with the Skill tool, with the effort folder's absolute path, and act on what it hands back as step 1 sets; its Resume finds the latest context version (its `CONTEXT` state), and every part below uses that version.
- **Find the dispatched parts:** run `sh <crucible.sh> find --effort '<the effort folder>' --kind dispatches` (its `--help` first, once per session, and again only when its contract is no longer in context), which prints the effort's dispatch files, newest first, and read each one's task with `jq -r '.task' <dispatch file>`. Take the dispatched parts from those tasks, never from a task you write from memory. When `find` prints at least one dispatch file and the conversation doesn't show which are this run's, ask as SKILL.md's Never sets, with `multiSelect: true`: the options are the newest dispatch files' tasks, at most 3, newest first, each with its date, read from its file name's leading Crucible ID (`<YYYYMMDDTHHMMSS>-<hex>`, the time it was made), then "Stop", and the human may also name a part with no dispatch yet. "Stop", picked alone or with others, ends the flow as SKILL.md's Never sets, with nothing more shown. Two dispatches with one task: the newest stands for the part. A dispatch whose task names another dispatch's reports replaces it; the replacement stands for the part. Its `<REPORT>` (Terms) is a file in the effort's `reports/development/`.

## One state per part

A part whose report check is still in context goes on by SKILL.md's steps. Every other part takes the first state below that fits. When `find` prints no dispatch file and no part is NOT-DISPATCHED, go to step 2, splitting the request as the latest context version's notes hold it. A report shown here ends its message; while parts remain, take the next one in the same turn, as step 5.3 sets.

- **NOT-DISPATCHED** — a part the conversation still shows, or one the human names when asked, with no dispatch file among those `find` printed: take it back through step 2 with the latest context version, so each `BUILD` part goes through `flow-agent-initialization` again.
- **MAY-RUN** — after a compaction in the same session, its Agent call shows no reply yet, so it may still be running in the background: wait for its reply as SKILL.md's Never sets, and check it as SKILL.md's Checking the reply sets. An agent error or no reply is `not run`, and a `report.sh check` exit 3 or 4 is handled as **REPORT-UNCHECKED** sets. Take only parts whose call has ended into the states below; when you can't tell, ask as SKILL.md's Never sets.
- **REPORT-CHECKED** — `<REPORT>` holds a report with a stamp (`jq -r '.dispatch // empty' <REPORT>` prints an ID): it passed its check already, so never check it again; show it (step 5), and step 6 takes it like every other report shown.
- **REPORT-UNCHECKED** — `<REPORT>` holds a report with no stamp: run `report.sh check` on it and act on its exit as SKILL.md's Checking the reply sets, except exits 3 and 4, which go as this bullet sets. Exit 3: render and show it as step 5 sets for an unstamped report, and record it as `incomplete`. Exit 4: take it as **NO-REPORT**.
- **NO-REPORT** — `<REPORT>` is empty or missing: the developer never reported. When a /clear or an interruption came after the dispatch and no reply was seen, ask whether its agent may still run, as SKILL.md's Never sets. On "it may still run", re-plan nothing for that part and record it as `not checked` for step 6. Otherwise re-plan the part through step 2, its task copied from the dispatch file, and hand that dispatch file in with it (step 2).

## A fix round

A part's rounds are its reports after the first (SKILL.md Terms), numbered in ID order, plus any round its todo item notes, with that item's N, report path and baseline. The part takes a state above for its first report, then each round's state below, in round order; each round goes to step 6.

- **FIX-CHECKED** — the round's report is stamped: show it (SKILL.md Fix rounds step 6); with no baseline in its todo item, show its full absolute path instead.
- **FIX-UNCHECKED** — non-empty, no stamp: run the round's check (SKILL.md Fix rounds step 5), and act on it as it sets.
- **FIX-SENT** — empty: ask whether its agent may still run, as **NO-REPORT** sets. On "it may still run", record the round as `not checked` for step 6; otherwise the developer is unreachable (SKILL.md Fix rounds).

The agent ID no longer in context or in its todo item: the next change goes the unreachable way (SKILL.md Fix rounds).

## Showing and failing

- **When its `LABELS:` line is no longer in context:** show it without step 5.1 and `--labels-file`, never with a line you composed.
- **`find` or a `jq` read fails, or prints `null`:** show the human its output, and record the part as `not checked` for step 6.
