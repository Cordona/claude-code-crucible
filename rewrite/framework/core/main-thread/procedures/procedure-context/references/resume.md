# Resume

How SKILL.md's Resume goes on in two cases: no context version yet (`CONTEXT-NONE`), and v1 written with step 7's question not answered on screen (`CONTEXT`). Read in those cases only.

`<crucible.sh>` is `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crucible/scripts/crucible.sh"`; run `sh <crucible.sh> --help` once, before its first use in a session, and not again in that session unless its contract is no longer in context (after a compaction). A `find` below that exits non-zero: show the human its stderr, and go on without it.

## Before v1 (CONTEXT-NONE)

No version means discovery is still open (SKILL.md steps 1–4).

1. **Find what is on disk:** run `sh <crucible.sh> find --effort '<effort folder>' --kind grills`, then `sh <crucible.sh> find --effort '<effort folder>' --kind drafts --label spec`, each a Bash call of its own. Read each grill file, and the newest spec draft (the first line of the second `find`), if any.
2. **What the work is:** the flow that loaded this skill names it (`flow-code-development` for code). Loaded by no flow (after a grill, say): ask the human what the work is, in step 3's message, and never guess.
3. **Say where things stand** in a few lines, from what step 1 read, and ask the human where they left off.
4. **The session scratchpad:** its answers file (SKILL.md step 3) and long-text file (SKILL.md step 1) survive only in the session that wrote them. When this session's scratchpad holds `context-answers-<effort folder name>.md`, read it and keep its answers, never asking them again; otherwise take nothing from memory, and ask the human for what is missing.
5. **Go on** from SKILL.md step 1 with the answer.

## After v1, "what next?" unanswered (CONTEXT)

When the conversation doesn't show the human's answer to SKILL.md step 7's question for the latest version, run `sh <crucible.sh> find --effort '<effort folder>' --kind dispatches`; its first line is the newest dispatch file. A dispatch answers the question only for the version it was made from: when there is one and `jq -r '.context.path' '<that dispatch file>'` prints the latest version's path, the human chose "Dispatch agents" for it already; hand over as SKILL.md step 8 sets. No dispatch file, or one made from an earlier version (or a `jq` that fails): ask the question again (SKILL.md step 7) before handing over.
