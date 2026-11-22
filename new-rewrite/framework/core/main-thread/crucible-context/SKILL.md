---
name: crucible-context
description: How main gathers an effort's context, the material agents work from, made of the approved spec, short notes, and references to what already exists. Use when material for the work turns up, when the human asks what the agents will get, or to take an entry out. Writes the draft context through its scripts; a version is cut when agents are sent. Not for finding out what the work is about, or for writing the spec.
---

# Context

The context is what the agents get besides their task: the approved spec, short notes written for the work, and references to outside files, folders and links. An agent knows nothing of this conversation, so what it needs from it has to be in the context; what it can find in the work itself doesn't.

Reference what already exists rather than copying it: a copy goes stale and costs every agent its tokens. Give each reference a one-line why that says what the agents need it for, such as "the retention rule the prune must follow", never just "docs". Write a note only for what was worked out here and lives nowhere else, and never put a secret in one: a note is sealed and read by every agent sent after it.

Read every entry yourself before the spec is approved, so the spec is written from all of it.

Take an entry out only with the human's reason. A version sent to agents never changes: what you add or take out later goes into the next version, which agents get when they are next sent.

The scripts are in this skill's `scripts/` folder, one per job; each one's `--help` is its contract.
