# The spec

How SKILL.md's The spec settles an effort's spec; read when SKILL.md step 4 runs it before v1, step 7 runs it after a grill, a ticket read after v1 calls for a revision, or a flow or the human's own ask runs it alone after v1. The approved spec and a recorded skip are as SKILL.md's The spec names them; "extend" is SKILL.md step 5. **Record the outcome:** before v1, it joins v1's entries (SKILL.md step 4), and no version is written here; after v1, extend.

`<crucible.sh>` is `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crucible/scripts/crucible.sh"`; run its `--help` once, before its first use in a session.

1. **Settled already, or not needed:**
   - **The approved spec is in the latest version (before v1: among v1's entries):** settled (step 6). After an ended grill, a ticket read after approval, or a settled answer from SKILL.md step 4's weighing, that changed its goal, done-when or scope, or when the human asks for a spec or to revise it: offer a revised spec, never forced; the human decides (step 5). On yes, or when a flow runs this for a revision the human accepted, step 2 then step 4, as a revision.
   - **A recorded skip in the latest version:** settled (step 6), unless the human now asks for a spec, or accepts a new spec offered because a change altered the work's goal, done-when or scope: then step 2 and step 4.
   - **The work now asked for builds nothing** (a grill about something else, such as the human's understanding of an existing system): no spec and no skip note; settled (step 6). Judge the work now asked for, never an earlier grill's.
   - **Otherwise:** step 2.
2. **Load `standard-spec`** with the Skill tool: it sets what a spec is and when one is needed. Missing: tell the human to install it, and stop (`stopped: standard-spec not installed`). Then step 4 for a revision or a spec the human asked for. Otherwise, run step 4's `find` first: a draft left with neither outcome recorded means the human already chose to draft, so step 4, and the skip is never offered again; none, step 3.
3. **Offer the spec after the talk, never at once:** before v1, only once you judge the work is understood (or the human asks). When a spec looks like overkill, say why in one line, in the normal talk, not a gate, and ask the human whether to skip it; otherwise offer to draft it. Act on the reply as step 5 sets.
4. **Draft it** with the human. Run `sh <crucible.sh> find --effort '<effort folder>' --kind drafts --label spec`; its first line is the newest spec draft.
   - **A draft is left, with neither a recorded skip nor the approved spec** (a talk a break cut off): Read it in full and go on from it, never from memory.
   - **The latest version holds a recorded skip or the approved spec, and the newest draft is not the approved spec's own path:** it may be from a talk the human ended. Give the human its absolute path and ask whether to go on from it or start fresh; a reply that is neither is answered, and the question asked again.
   - **Each version of the draft,** the first and every revision during the talk, is a new file, since a draft is written once: run `sh <crucible.sh> new --kind drafts --effort '<effort folder>' --label spec`, Read the empty file it prints, then Write the draft into it; the newest is the current draft.
   - **A non-zero exit from either command, or a failed Read or Write of the draft:** show the human its error, and stop (`stopped: spec draft not created`).
   - Hand the human each draft by its absolute path, never its text in the chat (CLAUDE.md §1), say what is still open, and ask for their approval; act on the reply as step 5 sets.
5. **The human's reply,** at the skip or draft offer, a revised or new spec's offer, or the approval ask:
   - **Approval** in their own words (a plain "yes" to your ask counts, quoted as given): record the newest draft as the approved spec's entry with its approval note. A revision also retires the old spec entry and its approval note; a spec after a skip retires the skip note; each retirement with its note saying why. Then step 6.
   - **"Skip" at the offer, or "no spec" or "just build it" at any point while drafting:** drafting ends; record the skip note in their words, then step 6. In a revision, or at a revised or new spec's offer, it ends with nothing recorded, and the version stays as it is (step 6).
   - **A yes at the draft offer, a no at the skip offer, a yes at a revised or new spec's offer, or a change to the draft:** step 4 (after step 2, when not yet loaded).
   - **Any other typed reply** (a question, say): a reply, not a choice. Answer it, and ask again at their next message; never read it as a yes, a no, "draft it" or approval.
   - **"Stop the work":** the drafts, and any context version, stay in the effort; stop (`stopped: spec not settled`). A later run goes on from the newest draft (step 4).
6. **Settled:**
   - **Run from SKILL.md step 4:** go back to it, which writes v1 with the outcome.
   - **Run from SKILL.md step 7 after a grill:** go back to it, which asks "what next?".
   - **Run alone after v1 on the human's own ask:** once its extension is written, SKILL.md step 7 asks "what next?" again. With nothing recorded, tell the human in one line that the context stays as it was, and end the turn with no "what next?".
   - **Run alone by a flow, or after a ticket read after v1:** hand over as SKILL.md step 8 sets, with no "what next?".
   - Every stop here ends as SKILL.md step 8 sets, its step named `references/spec.md` step `<n>`.
