# crucible-dynamic-flow: event shapes, for approval

Each event carries the usual envelope (`type, seq, at, by, claude_session_id`); only the bodies are shown. A flow's id is the seq of its `flow.agreed`. A field exists only if something reads it.

## flow.agreed

```json
{
  "goal": "Know what we're building and why",
  "done_when": { "event": "context.cut" },
  "steps": [
    { "id": 1, "do": "Find out what the effort is about", "uses": "crucible-discovery",
      "done_when": { "criteria": "the human confirmed the goal and what must not break", "by": "human" } },
    { "id": 2, "do": "Grill the open goal", "uses": "crucible-grill", "done_when": { "event": "grill.ended" } },
    { "id": 3, "do": "Make the change", "uses": "code-build", "done_when": { "criteria": "all tests green" } }
  ]
}
```

- **`done_when`**, on a step and on the flow alike, is either `{"event": "<type>", "match"?: {<body field>: <value>}}` or `{"criteria": "<one-line yes/no>", "by"?: "human"}`.

## flow.changed

```json
{ "flow": 4, "reason": "The human asked for a grill before the spec",
  "ops": [ { "add": { "id": 5, "do": "…", "uses": "…", "done_when": { "event": "grill.ended" } }, "before": 2 },
           { "skip": 3, "why": "No findings to fix" },
           { "move": 5, "before": 1 },
           { "reopen": 2, "why": "The spec was revised" } ] }
```

## flow.step.done

The two kinds of evidence go in two separate fields, never one field that holds either a number or text:

```json
{ "flow": 4, "step": 2, "kind": "event", "event": 12 }
{ "flow": 4, "step": 3, "kind": "main", "evidence": "ran npm test: 142 passed, 0 failed" }
{ "flow": 4, "step": 1, "kind": "human", "evidence": "Yes, that's the goal, and billing must not break" }
```

## flow.ended

```json
{ "flow": 4, "outcome": "done", "kind": "event", "event": 31 }
{ "flow": 4, "outcome": "done", "kind": "main", "evidence": "the login works on staging" }
{ "flow": 4, "outcome": "dropped", "words": "The client cancelled the feature" }
```

- **`done`** needs every step done or skipped, plus the flow's own `done_when` met. An event is checked by the script. A criterion needs an evidence line.
- **`dropped`** needs the human's words.

## Fields and their readers

| Field | Read by | Why |
|---|---|---|
| `goal` | `flow-show.sh`, the Stop hook's line | What the flow is about |
| `done_when` (flow) | `flow-end.sh` | Whether the goal was reached |
| `steps[].id, do, uses, done_when` | `flow-show.sh`, `flow-step-done.sh`, `flow-change.sh` | The steps, and the evidence each needs |
| `flow` | every flow script, the hook | Which flow an event belongs to |
| `reason`, `why` | `flow-show.sh` (on request), audit | Why it changed |
| `ops` | `flow-show.sh`, `flow-step-done.sh` | The current steps, once replayed |
| `step` | `flow-show.sh`, the hook | Which step is done |
| `kind` | `flow-show.sh` (a mark for checked, claimed by main, or confirmed by the human) | Facts and claims, kept apart in the track |
| `event` | `flow-step-done.sh` (one event, one step), `flow-show.sh` | Which event proved it |
| `evidence` | `flow-show.sh` (on request), audit | How a criterion was verified |
| `outcome`, `words` | `flow-show.sh`, audit | How the flow ended |

**Rules the scripts enforce:**
- Each event proves at most one step in the whole effort. The flow-level check doesn't count as a claim.
- After a `reopen`, only evidence newer than the reopen counts.
- Order is advisory: any open step can be marked done.
- A flow can't end `done` while its own criterion is unmet. Main and the human either add steps, or end it `dropped` with the reason.
