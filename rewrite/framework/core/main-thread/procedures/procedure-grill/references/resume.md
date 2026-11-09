# Resuming a grill

Which grill is in progress and its one next step; read at SKILL.md's Resume, after a compaction, an interruption or a new session, before any other step. Step numbers are SKILL.md's.

Take the effort folder `procedure-resume` hands over, then run `<grill.sh> list --effort '<effort folder>'` (SKILL.md Steps set `<grill.sh>` and its `--help`), and take the first state its `GRILL:` lines fit:

- **GRILL-OPEN** — one or more `open` lines:
  - **One `open`:** its path is the grill file; ask its next round (step 5) from its open questions, never a settled one.
  - **Two or more `open`:** ask the human which with one AskUserQuestion. Each option is a grill's topic with its open count, in the order printed (newest first), the first marked (Recommended). The grill picked is the grill file: ask its next round as above.
- **GRILL-ENDED** — no `open` line, an `ended` line, and an ended grill's copy not yet cut: `context.sh latest`, run as step 3 sets, exits 7, and the `DOCS_FOLDER:` it prints holds `grill-<ID>.json`, `<ID>` an `ended` line's grill file's. Run `context.sh spec --status` as step 10 sets and load `procedure-context` with the Skill tool, with the effort folder and that `grill-<ID>.json` path:
  - **`SPEC: approved`,** with or without a version: run its step 5 for the ended grill, then its step 7.
  - **`SPEC: none`:** run its Resume.
  - **Any other exit:** as step 10 sets.
- **GRILL-NONE** — no line, or no ended grill's copy waiting in a docs folder: hand back to `procedure-resume`, which takes its next line.
