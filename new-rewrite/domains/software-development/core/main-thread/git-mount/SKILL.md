---
name: git-mount
description: Puts trees' committed work into the human's own checkout as uncommitted changes so they can try it, and takes it out again byte for byte. Use when the human wants to try a tree's work in their checkout, or to see or undo a mount. Writes mount.made and mount.undone through its scripts; never touches the human's index or refs, and never merges.
---

# Git mount

Propose `git-mount/mount` when the human wants to try a tree's work in their own checkout. Name on your card the trees, the repository, and what the human's checkout holds that the mount will leave alone; the human decides at a plain gate.

Landing the work on the human's branch stays the human's own step: a mount is only a try.

Before offering a remount, read the mount's status: a tree that moved on, a HEAD that moved, or paths the human edited are the human's to weigh. When the human committed the mount, undoing it only forgets it.

The scripts you run are in this skill's `scripts/main/` folder; each one's `--help` is its contract.
