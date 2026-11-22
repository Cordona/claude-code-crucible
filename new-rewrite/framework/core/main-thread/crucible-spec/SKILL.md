---
name: crucible-spec
description: How to draft an effort's spec with the human, the approved what and why every agent works from, and record its approval. Use before an effort's work is sent to agents and no approved spec covers it, when the human asks for a spec, or when the goal, done-when or scope changes. Writes spec drafts in the effort's spec/ folder and, through its script, the approved spec. Not for how the work is done.
---

# Spec

A spec is the contract between the human and the agents: what the work must achieve and why, never how (no files, structure or step list). It is as small as the work: a one-line fix gets a few lines.

It has five sections, each holding only its own substance:

```markdown
## Goal
Prune data older than 90 days, nightly, so the disk stops filling.
## Done when
No row older than 90 days remains after the nightly run.
## Scope
In: the prune job. Out: archiving.
## Constraints
Never delete live data; a schema change needs the human's OK first.
## Open points
None.
```

At approval, no open point is left, unless the human chooses to leave it to the agents. A tool or technology goes in only when the human requires it, and the project's own rules never do.

Draft it with the human. Each revision is a new file in the effort's `spec/` folder. The script in this skill's `scripts/` folder records the approval; its `--help` says what the gate must record. Read it, ask at that recorded gate with the draft itself as the card, then run it. Revise an approved spec only when the goal, done-when or scope changes, never for a small change.
