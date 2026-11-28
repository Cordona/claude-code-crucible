---
name: git-commit
description: Commits a tree's changes on its crucible/ branch as a signed commit in the effort's identity for the repository, with the message written from a small JSON input. Use when work in a tree has to be committed. Writes git objects and the branch only; never changes git config, runs no hook, writes no event.
---

# Git commit

When a commit comes back `signed: false`, carry that into whatever reports it, so the human sees it.

The scripts you run are in this skill's `scripts/main/` folder; each one's `--help` is its contract.
