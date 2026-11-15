# Resume

How SKILL.md's Resume goes on in two cases: no version cut yet (`CONTEXT-DOCS` with no `CONTEXT_FILE:` line, or `CONTEXT-NONE`), and a version with a spec gate's answer not on screen (`CONTEXT`, or `CONTEXT-DOCS` with a `CONTEXT_FILE:` line).

`<context.sh>` and `<crucible.sh>` are as SKILL.md sets. `<grill.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-grill/scripts/grill.sh"`, `<settings.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-git-setup/scripts/settings.sh"` and `<seats.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-git-worktree/scripts/seats/seats.sh"`. Run `<crucible.sh> --help`, `<grill.sh> list --help`, `<settings.sh> --help` and `<seats.sh> --help` once each, before its first use in a session; run one again in that session only when its contract is no longer in context (after a compaction). Never list or read the effort's `events/` to find something: these scripts read it; Read only a file there that a script's line names. When a read below exits non-zero, other than as step 2 sets, or its `--help` fails, show the human its stderr and go on without it.

**An open spec talk:** the newest spec draft, the first line of `<crucible.sh> find --effort '<effort folder>' --kind drafts --label spec`, whose text isn't the newest approved spec's, the file `<context.sh> spec --effort '<effort folder>' --status` names on its `SPEC_FILE:` line (with none approved, any draft). It goes on through SKILL.md's The spec, which shows its approval gate again, whether or not the work seems understood yet: a draft is not approved until the human answers its gate, whatever the talk said.

## No version yet

1. **Find what is on disk:** run `<grill.sh> list --effort '<effort folder>'`, then the drafts `find` of an open spec talk (above). Read each open grill's draft (a `GRILL:` line whose second field is `open`), the newest spec draft, every file in the docs folder (the `DOCS_FOLDER:` line, `CONTEXT-DOCS` only; each ended grill's copy, `grill-<n>.json`, is one of them) and `entries.json` beside `docs/`, when there.
2. **The human already chose "Dispatch agents"** when the docs folder holds `spec.md` and the effort shows a step only that answer leads to: `<settings.sh> get --effort '<effort folder>'` exits 0 (a git setup is saved), or `<seats.sh> list --effort '<effort folder>'` prints a list holding a seat. Then hand over as SKILL.md step 8 sets, with no "what next?". Act on each other `get` exit as its `--help` sets: 5, no git setup yet, is not chosen; 2, fix the call; 3 or 4, show the human its stderr, and stop as SKILL.md step 8 sets (`stopped: git settings not read`). Otherwise (`get` exits 5 and no seat, or the `seats.sh list` read failed), step 3.
3. **What the work is:** the flow that loaded this skill names it. When no flow loaded this skill (after a grill, say), ask the human what the work is in step 4's message; never guess.
4. **Say where things stand** in a few lines, from what step 1 read, an open spec talk included, and ask the human where they left off. What the talk settled before the first spec draft is on no disk: take nothing from memory, and ask the human for what is missing.
5. **Go on** with the answer: from SKILL.md's The spec when step 1 found an open spec talk, otherwise from SKILL.md step 1, with what is on disk; add nothing again.

## A version

Run the drafts `find` of an open spec talk (above), and Read the latest version, the file `<context.sh> latest`'s `CONTEXT_FILE:` line names. When a spec talk is open, go on through SKILL.md's The spec, whose approval gate names the draft, its goal and open points; then hand over as SKILL.md step 8 sets.
