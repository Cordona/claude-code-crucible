---
name: crucible-dynamic-flow
description: Proposes to the human a flow of declared steps toward a goal inside an effort, agrees it at a gate, records changes, and tracks what is done and left from the effort's events. Use when an effort's work is about to start, when the pre-work is done and the next work is chosen, when the human changes the plan, when returning to an effort, or when a flow reminder names a step. Writes only flow events, through its scripts.
---

# Dynamic flows

A flow is the steps toward one goal that you and the human agree before the work, each a step a piece of the framework declares and each ended by that piece's own event. You choose the steps and suggest an order; the human agrees it at a gate, or says no flow.

Before an effort's work starts, run `flow-candidates.sh --stage prepare` and propose a flow from the steps it lists that fit the work. Once those steps are done, run `flow-candidates.sh --stages` and scan the stage the next work belongs to; when no stage fits it, go on without a flow.

A flow names only the steps the scan lists, by their keys, for example:

```json
{
  "goal": "Know the work well enough to build it",
  "steps": [
    { "id": 1, "step": "crucible-context/build-context" },
    { "id": 2, "step": "crucible-grill/grill" },
    { "id": 3, "step": "crucible-spec/specify" }
  ]
}
```

What each step does, and the event that ends it, come from its declaration. The same step may appear twice, under two ids. `flow-agree.sh` records the agreement; its `--help` says what the gate must record. Read it, then ask at that recorded gate with the card `flow-card.sh` prints for the flow file.

Mark each step when its event is there, and end the flow once every step is done or skipped, or drop it with the human's words. When the human changes the plan, record the change; a change you want yourself goes to the human first. When you return to an effort, look at its open flows first.

The scripts are in this skill's `scripts/` folder, one per job; each one's `--help` is its contract.
