# The five record fixes: verdict (2026-11-23)

By Crucible Fable Reviwer, for the owner. I judged the evidence and the constitution, not the code. Nothing here is a go.

## Verdict: all five are done; one coupling should move to the gate

(b) and (c) are right as they are. (a) works and is proven, but it puts knowledge of the gate's event shape into a domain script, which is the thing we removed elsewhere. The gate should offer the reader.

## What I did

- **Reran the three runs named:** events and effort match the stored outputs exactly. git-worktree gives 330 PASS, 0 FAIL.
- **One thing to know about my rerun:** the first attempt showed 4 failures. They were scripts being rewritten while the run read them (the help cut in progress), not defects. Against a frozen copy of the tree the run passes whole. While a builder edits the tree, evidence runs against the live tree can't be trusted, mine or anyone's.
- **Ran the help checker** on all 82 scripts, and on a script I put in the wrong folder on purpose.
- **Read the hand-off, the spec's known limits and the agent-run map.**

Nothing was left running.

## (a) The drop's rerun after a held lock

**The behaviour is proven:**
- the first attempt exits 6 with the tree gone and still listed as live;
- the rerun writes exactly one `worktree.dropped`, carrying the yes the first attempt read;
- a second rerun is refused;
- a yes already used does not carry a later drop of a tree with the same name.

**The coupling: not acceptable as it stands. The gate should offer the reader.**

- Our own rule, applied three times already (the flow, the spec, the identity): nobody outside the gate reads `gate.answered`. The identity's rule was trimmed for exactly this.
- The reason has not changed. The gate owns its event's shape. A domain script that reads `record`, `subject` and `seq` itself breaks silently the day the gate changes them, and nothing in the gate's own evidence would show it.
- What the drop needs is small and general: **the accepted answers for a record whose subject starts with a given text, given after a given event.** That is a second way of asking the gate's existing reader, not a new piece. "Unused" stays the drop's own question, answered from its own events, as today.
- This moves one read to its home. The behaviour and its evidence stay as built.

**One oddity to accept, not fix.** When the first attempt needed no yes (nothing unlanded) and then hit the lock, the rerun demands one, because with the folder and branch gone it can no longer tell that nothing was lost. The human is asked to say yes to a drop that has already happened. It is the safe side and the help says it. The card for that gate should say plainly that the tree is already gone and the yes records it; that is main's to write, and one sentence in the help's `Requires` would prompt it.

**Weight.** This is a held lock at the moment of a drop: rare today. I would not add anything more to it than the move above.

## (b) `effort-list.sh` with a damaged effort: right

It lists the healthy efforts, names each damaged one on stderr with the reason, and exits 3. The help says what 3 means. The other effort scripts still refuse outright on a damaged effort, which is correct: inside one effort the rule stays all or nothing.

## (c) The record

- **The help checker** is at `.crucible/docs/rewrite-next/tools/help-check.sh`. It passes all 82 scripts, and it caught the script I misplaced ("in scripts/main/, but its help says it is not for main"). The hand-off names it and says it is a development tool, not shipped.
- **The hand-off** names the three kinds of exit 6 and which script is of which kind.
- **The domain spec** no longer carries the stale limit. It has the `--abort` limit and the mount-undo limit, both stated with their reason.
- **The agent-run map** carries the open question of what a dispatched agent may read.

One small thing: the hand-off writes the checker's path as `tools/help-check.sh`. There is also a `tools/` folder at the repository root. Write the path in full so nobody looks in the wrong one.

## What to do

1. Give the gate's reader a way to list the accepted answers for a record by the start of the subject and after an event; have `worktree-drop.sh` ask it. Needs the owner's go, since it touches core.
2. Write the checker's full path in the hand-off.
3. Rerun the full evidence once the help cut is finished and the tree is still.
