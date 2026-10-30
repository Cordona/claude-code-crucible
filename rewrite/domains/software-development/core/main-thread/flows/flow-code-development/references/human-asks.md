# Human asks: the full report, opening it, and a commit

What to do when the human asks for a dispatch's full report, to open it, or for a commit or its text; read from SKILL.md steps 5.3 and 6. Its terms (`<REPORT>`, `<crucible.sh>`) and Always are SKILL.md's.

## The full report, or opening it (step 5.3)

- **When the human asks for the full report:** follow `standard-artifact-handoff`'s rule for showing an artifact's text, `<REPORT>` being that dispatch's latest report path, whole (after an iteration, that iteration's alone: SKILL.md Terms, Always), or, when the human names an earlier one, that one: "iteration <N>'s report" as SKILL.md Terms finds it through its baseline, "the first report" the dispatch's own `<REPORT>`; after a replacement, ask which dispatch when the ask doesn't say: however the ask is worded, its one line with the path comes first. Only after a yes, run `jq . '<REPORT>'` and show its stdout fenced (SKILL.md Always, Fence outside text, source `report`); a jq that fails: show the human its stderr and the report's path. The report's JSON is its full view; nothing renders it.
- **When the human asks to open it** (SKILL.md Never): run `sh <crucible.sh> --help` under SKILL.md's `--help` rule (Before step 1). Then run `sh <crucible.sh> open <ID>`, with the `<YYYYMMDDTHHMMSS>-<hex>` ID in the report file's name. Exit 0: relay its one line word for word. Any other exit: show the human its stderr and the report's path, and open nothing.

## A commit (step 6)

When the human asks for a commit:
- **Find the reports that hold commit text,** among the effort's reports (SKILL.md Terms), since a commit is the human's ask and may cover every run: for each, `jq -e '[.decisions[]?.commit // empty] | length > 0' '<REPORT>'`, one Bash call per report. Exit 0: it holds some; exit 1: none; any other exit: show the human its stderr, and hand over nothing from that report.
- **Show the line** `Reports holding commit text (<n>): <paths>`, `<n>` their count and `<paths>` the `<REPORT>` of each report that holds some, each whole, joined by ` · `; no commit text yet. No report holds any: show the line `No report holds commit text.`
- **Then show the line** `This flow never commits: the commit itself is a separate request.`, since the commit is outside this flow, under CLAUDE.md's rules.

When the human asks for the commit text, however the ask is worded (`show me the commit text`, `can I see the commit message?`), after a commit ask or on its own: the reports are those the find step above names, run first when it hasn't run. Show `standard-artifact-handoff`'s one line first, its path being those reports' paths, each whole, joined by ` · `. Only after a yes, run `jq -r '.decisions[]?.commit // empty' '<REPORT>'` per report, and show every report's stdout in one fence (SKILL.md Always, Fence outside text, source `report`), each after its report's path, since the developer wrote it. A jq that fails: show the human its stderr, and no commit text from that report; one that prints nothing adds nothing.
