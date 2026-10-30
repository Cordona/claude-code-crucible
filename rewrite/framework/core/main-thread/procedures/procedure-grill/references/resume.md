# Resuming a grill

Which grill is in progress and its one next step; read at SKILL.md's Resume, after a compaction, an interruption or a new session, before any other step. Step numbers are SKILL.md's.

Take the effort folder `procedure-resume` hands over, then run `<grill.sh> list --effort '<effort folder>'` (SKILL.md Steps set `<grill.sh>` and its `--help`), and take the first state its `GRILL:` lines fit:

- **GRILL-OPEN** — one or more `open` lines:
  - **One `open`:** its path is the grill file; ask its next round (step 5) from its open questions, never a settled one.
  - **Two or more `open`:** ask the human which with one AskUserQuestion, each option a grill's topic with its open count, in the order printed (newest first), the first marked (Recommended); wait for the answer, as Never sets. The grill picked is the grill file: ask its next round as above.
- **GRILL-ENDED** — no `open` line, and an `ended` grill not yet in the context: its path is not among the latest version's `paths` entries, or there is no version yet (run `context.sh latest` as step 3 sets). Its end never reached the context. With a version: resume step 10 with it, from its `context.sh latest`. With no version yet: discovery is still open, and never restarts. Load `procedure-context` with the Skill tool and run its Resume with the effort folder; its `CONTEXT-NONE` state reads the grill files and the newest spec draft, says where things stand and asks the human where they left off, and the grill file waits there as a path for v1.
- **GRILL-NONE** — no line, or every ended grill already in the context: hand back to `procedure-resume`, which takes its next line.
