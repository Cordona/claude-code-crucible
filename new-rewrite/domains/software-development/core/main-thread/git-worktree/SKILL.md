---
name: git-worktree
description: Prepares and tends the git worktrees an effort's code-writing work happens in, so it never happens in the human's checkout - reads the facts, cuts a tree from the right base, moves, catches up, diffs, discards and drops it. Use whenever the coming work writes code, and to keep its trees in step or clear them away. Writes worktree.* events through its scripts; never touches the human's checkout, index or refs.
---

# Git worktree

Work that writes code gets a tree of its own; a reader or a reviewer needs none.

**Cutting is always a step; no tree is cut quietly.** Propose `git-worktree/cut-worktree` in the flow, one step line per tree. Show one card of your own for every tree the work needs: each one's name, repository and base, with the facts, your reasoning and your recommendation. The human decides for all of them at one plain gate.

Whether and when a tree takes in another's work is yours and the human's to decide.

When a script asks for a recorded yes, ask at a recorded gate with the record and subject it names, then run it again.

The scripts you run are in this skill's `scripts/main/` folder; each one's `--help` is its contract.
