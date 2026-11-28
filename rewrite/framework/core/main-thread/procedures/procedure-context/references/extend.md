# Add to the context

How SKILL.md step 5 adds to the context once the spec is approved, before or after a cut. Read it when a new entry enters a running effort, a contradiction found then is settled, a grill ends, or the spec changes.

Everything new goes into the docs folder, and the next dispatch the human approves cuts it; nothing is cut here. Run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-context/scripts/context.sh" docs --effort '<effort folder>'` and keep its `DOCS_FOLDER:` path: before the first cut it is the folder discovery wrote, after a cut a new one.

1. **Read the new entries in full** and weigh them against the latest version, if any, and the docs folder, as SKILL.md steps 2 and 3 set, before anything is written.
2. **Write them as SKILL.md step 1 sets:** `add` each new outside path or link, `drop` one the human takes back (one in the latest version too), with the human's reason, and write a short `<name>.md` in the docs folder for new research or a note. An ended grill is already in the docs folder as `grill-<n>.json`.
3. **A settled answer, or anything that changes the approved spec's goal, done-when or scope:** run SKILL.md's The spec, for its revision; its approval replaces the docs folder's `spec.md`.
4. **Hand over** as SKILL.md step 8 sets, telling the calling flow the context changed; or, as SKILL.md step 7 sets, ask what next.
