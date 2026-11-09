# Resume

How SKILL.md's Resume goes on in two cases: no version cut yet (`CONTEXT-DOCS` with no `CONTEXT_FILE:` line, or `CONTEXT-NONE`), and a version with a spec gate's answer not on screen (`CONTEXT`, or `CONTEXT-DOCS` with a `CONTEXT_FILE:` line).

`<context.sh>` and `<crucible.sh>` are as SKILL.md sets; run `<crucible.sh> --help` once, before its first use in a session; run it again in that session only when its contract is no longer in context (after a compaction). When a `find` below exits non-zero, show the human its stderr and go on without it.

**An open spec talk:** the newest spec draft, the first line of `<crucible.sh> find --effort '<effort folder>' --kind drafts --label spec`, whose text isn't the newest approved spec's, the file `<context.sh> spec --effort '<effort folder>' --status` names on its `SPEC_FILE:` line (with none approved, any draft). It goes on through SKILL.md's The spec, which shows its approval gate again, whether or not the work seems understood yet: a draft is not approved until the human answers its gate, whatever the talk said.

## No version yet

1. **Find what is on disk:** run `<crucible.sh> find --effort '<effort folder>' --kind grills`, then the drafts `find` of an open spec talk (above). Read each grill file, the newest spec draft, every file in the docs folder (the `DOCS_FOLDER:` line, `CONTEXT-DOCS` only) and `next-entries.json` beside `docs/`, when there.
2. **The human already chose "Dispatch agents"** when the docs folder holds `spec.md` and any of these is on disk, since only that answer leads to them: the effort folder's `settings.json` or `seats.json` (the work's git setup), a plan record that `<crucible.sh> find --effort '<effort folder>' --kind plans` prints, or a `git-setup` gate record that `<crucible.sh> find --effort '<effort folder>' --kind cache/gates --label git-setup` prints. Then hand over as SKILL.md step 8 sets, with no "what next?". Otherwise, step 3.
3. **What the work is:** the flow that loaded this skill names it. When no flow loaded this skill (after a grill, say), ask the human what the work is in step 4's message; never guess.
4. **Say where things stand** in a few lines, from what step 1 read, an open spec talk included, and ask the human where they left off. What the talk settled before the first spec draft is on no disk: take nothing from memory, and ask the human for what is missing.
5. **Go on** with the answer: from SKILL.md's The spec when step 1 found an open spec talk, otherwise from SKILL.md step 1, with what is on disk; add nothing again.

## A version

Run the drafts `find` of an open spec talk (above), and Read the latest version. When a spec talk is open, say where things stand in a few lines, and go on through SKILL.md's The spec; then hand over as SKILL.md step 8 sets.
