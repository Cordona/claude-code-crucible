# Human asks: the full report, opening it, and a commit

What to do when the human asks for a dispatch's full report, to open it, or for a commit or its text; read from SKILL.md steps 5.3 and 6. Its terms (`<REPORT>`, `<crucible.sh>`) and Always are SKILL.md's.

## The full report, or opening it (step 5.3)

- **When the human asks for the full report:** follow `standard-artifact-handoff`'s rule for showing an artifact's text, `<REPORT>` being that dispatch's report path, whole (after a fix round, every report of the dispatch in round order, latest last: SKILL.md Terms): however the ask is worded, its one line with the path comes first. Only after a yes, run `jq . '<REPORT>'` and show its stdout fenced (SKILL.md Always, Fence outside text, source `report`); a jq that fails: show the human its stderr and the report's path. The report's JSON is its full view; nothing renders it.
- **When the human asks to open it** (SKILL.md Never): run `sh <crucible.sh> --help` once, before its first use in a session, and not again in that session unless its contract is no longer in context (after a compaction); every other call runs only the command its step names. Then run `sh <crucible.sh> open <ID>`, with the `<YYYYMMDDTHHMMSS>-<hex>` ID in the report file's name. Exit 0: relay its one line word for word. Any other exit: show the human its stderr and the report's path, and open nothing.

## A commit (step 6)

When the human asks for a commit:
- **Find the reports that hold commit text:** for each report, `jq -e '[.decisions[]?.commit // empty] | length > 0' '<REPORT>'`, one Bash call per report. Exit 0: it holds some; exit 1: none; any other exit: show the human its stderr, and hand over nothing from that report.
- **Show the line** `Commit text is in each report's decisions: <paths>`, `<paths>` the `<REPORT>` of each report that holds some, each whole, joined by ` · `. No report holds any: show the line `No report holds commit text.`
- **Then show the line** `This flow never commits: the commit itself is a separate request.`, since the commit is outside this flow, under CLAUDE.md's rules.

When the human asks for the commit text, however the ask is worded (`show me the commit text`, `can I see the commit message?`), after a commit ask or on its own: show `standard-artifact-handoff`'s one line first, with the report paths. Only after a yes, run `jq -r '.decisions[]?.commit // empty' '<REPORT>'` per report and show its stdout once, fenced (SKILL.md Always, Fence outside text, source `report`), since the developer wrote it. A jq that fails or prints nothing: show the human its stderr, and show no commit text from that report.
