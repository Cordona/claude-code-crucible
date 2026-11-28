---
name: remotes
description: Reads a GitHub pull request or GitLab merge request, and the review threads on it, read-only, and records them in an effort so a reviewer agent can review the change or judge its review. Use when the human points to a pull or merge request to review, or wants an outside review of one judged. Not for issues (trackers) or for posting to the host.
---

GitLab can't tell an AI reviewer from a person. When the human names one, or the threads make it plain, pass its account as `--bot`.

The scripts you run are in this skill's `scripts/main/` folder; each one's `--help` is its contract.
