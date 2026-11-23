---
name: git-push
description: Takes a tree's work public by pushing its branch to a remote under the same name, on the human's recorded yes - never a protected branch, never prompting, with a time limit. Use when the human wants a tree's work on a remote, to share it or open a pull request from it, also after the effort has closed. Writes push.made through its script; never pushes anything the human did not say yes to.
---

# Git push

Propose `git-push/push-tree` when the human wants a tree's work on a remote. A push is public and hard to take back, so it is never proposed on your own initiative and never folded into another step.

Each push needs its own recorded yes. Show a card naming the tree, its branch, the exact tip and the commits that go with it, the remote and its URL, and, when the tree moved since its last push there, that the push replaces the remote branch by lease. Ask at a recorded yes gate with the record and subject the script names; one yes pushes one tip once.

A push that was rejected or timed out changed nothing. Say why, and leave what to do next to the human: never retry with force, and never push again without a new yes.

The scripts you run are in this skill's `scripts/main/` folder; each one's `--help` is its contract.
