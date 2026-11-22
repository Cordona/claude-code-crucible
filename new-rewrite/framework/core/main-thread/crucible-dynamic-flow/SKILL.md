---
name: crucible-dynamic-flow
description: Agrees with the human the steps toward a goal inside an effort, records changes to them, and tracks what is done and what is left, from the effort's events. Use when a goal inside an effort needs several steps, when the human changes the plan, when returning to an effort, or when a flow reminder names a step. Writes only flow events, through its scripts. Not for small goals.
---

# Dynamic flows

When a goal needs several steps, propose a flow built from the skills and pieces you know, agree it with the human at a gate, then follow it. For routine work, recommend a flow the human can accept as it is; a small goal needs no flow.

A step is an outcome the human would ask about, not a task of yours; keep your own tasks in your to-do list. Each step's `done_when`, and the flow's own, is a yes or no: an event a piece writes, or a short criterion. Name an event only when you know a piece writes it; otherwise use a criterion. For example:

```json
{
  "goal": "Know enough about the work to specify it",
  "done_when": { "criteria": "the human says the spec says what they want", "by": "human" },
  "steps": [
    { "id": 1, "do": "Find out what the work is about and gather what it needs", "uses": "crucible-discovery", "done_when": { "event": "context.cut" } },
    { "id": 2, "do": "Grill the open goal", "uses": "crucible-grill", "done_when": { "event": "grill.ended" } },
    { "id": 3, "do": "Draft and approve the spec", "uses": "crucible-spec", "done_when": { "event": "spec.approved" } }
  ]
}
```

A grill belongs only where the goal is still open. A check no piece proves takes a criterion, as the flow's own does here.

Mark each step as it finishes, and end the flow: done when its own check is met, or dropped with the human's reason. When the human changes the plan, record the change; their words are the agreement. A change you want yourself, such as skipping a step or revising a check, goes to the human first. When you return to an effort, look at its open flows first.

The scripts are in this skill's `scripts/` folder, one per job; each one's `--help` is its contract.
