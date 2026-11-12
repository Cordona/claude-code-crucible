# Resuming a grill

Which grill is in progress and its one next step; read at SKILL.md's Resume, after a compaction, an interruption or a new session, before any other step. Step numbers are SKILL.md's.

Take the effort folder `procedure-resume` hands over, then run `<grill.sh> list --effort '<effort folder>'` (SKILL.md Steps set `<grill.sh>` and its `--help`), and take its `open` lines:

- **One `open`:** its path is the grill file; ask its next round (step 5) from its open questions, never a settled one.
- **Two or more `open`:** ask the human which with one AskUserQuestion. Each option is a grill's topic with its open count, in the order printed (newest first), the first marked (Recommended). The grill picked is the grill file: ask its next round as above.
