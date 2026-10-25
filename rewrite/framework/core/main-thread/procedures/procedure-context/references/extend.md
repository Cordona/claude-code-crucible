# Extend

How SKILL.md step 5 writes the next context version; read when a new entry enters a running effort, a contradiction found after a version was written is settled, a grill ends, or step 4 exits 3 for an effort whose context already holds a version.

Read the new entries in full and weigh them against the latest version, as SKILL.md steps 2 and 3 set, before anything is written. Then run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-context/scripts/context.sh" extend --from '<the latest version>'` with the new entries, written as SKILL.md step 4 sets. To retire an entry, add `--retire '<list>:<n>'`, `<list>` being `paths`, `links` or `notes` and `<n>` its position, from 1, in the version extended, plus a `--note` saying why. After a grill, its file is the new entry, entered as SKILL.md step 1 sets, and each note a settled answer replaced is retired. Act on its exit as SKILL.md step 4 sets, with these changes:

- 0 with a `CONTEXT_FILE:` line: that path replaces the old one as the latest version; read any new tracker link as SKILL.md step 4 sets.
- 3 naming another version as the latest: weigh the new entries against that version, and extend from it, at most twice; then show the human the stderr, and stop as SKILL.md step 8 sets.
