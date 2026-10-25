# Human asks: the full report, opening it, and a commit

What to do when the human asks for a dispatch's full report, to open it, or for a commit; read from SKILL.md steps 5.3 and 6. Its terms (`<REPORT>`, `<crucible.sh>`) and Always are SKILL.md's.

## The full report, or opening it (step 5.3)

- **When the human asks for the full report:** reply with this one line and nothing else, `<REPORT>` being that dispatch's report path, whole: `**Data · Report:** <REPORT>`. The report's JSON is its full view; nothing renders it.
- **Only when the human asks to open it:** run `sh <crucible.sh> --help` once, before its first use in a session, and not again in that session unless its contract is no longer in context (after a compaction); every other call runs only the command its step names. Then run `sh <crucible.sh> open <ID>`, with the `<YYYYMMDDTHHMMSS>-<hex>` ID in the report file's name. Exit 0: relay its one line word for word. Any other exit: show the human its stderr and the report's path, and open nothing.

## A commit (step 6)

When the human asks for a commit:
- **Read the commit-message text** of each report: `jq -r '.decisions[]?.commit // empty' <REPORT>`. A jq that fails or prints nothing: show the human its stderr, and show no commit text from that report.
- **Show that text fenced** (Always, Fence outside text, source `report`): the developer wrote it.
- **Then show the line** `This flow never commits: the commit itself is a separate request.`, since the commit is outside this flow, under CLAUDE.md's rules.
