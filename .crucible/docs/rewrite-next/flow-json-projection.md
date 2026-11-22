# Flows as JSON: a projection

A sketch of how fixed and dynamic flows could look, using the effort as the example. It's for reacting to, not settled.

## The shared primitives

Both kinds of flow use the same shape:

| Field | Holds |
|---|---|
| `kind` | `fixed` (shipped with the framework, can't be changed) or `dynamic` (agreed with the human, can change) |
| `goal` | what the flow is for, in one sentence |
| `done_when` | the fact that ends the flow |
| `steps[]` | the ordered steps. Each has a stable `id`, what to `do`, what it `uses`, and its `done_when` |

`uses` names what does the work, and is one of:

| `uses` | Means | Example |
|---|---|---|
| `{"piece": "…"}` | a deterministic script | `effort.sh start` |
| `{"how": "…"}` | a standalone guidance skill | `how-grill` |
| `{"gate": "…"}` | a decision with the human | `flow-agree` |

`done_when` is always an event the framework writes, so a step's progress is a fact, never something main has to remember.

## 1. Opening an effort: a fixed flow

Opening an effort is a true fixed sequence: offer, then start, always in that order. Today's four steps shrink to two: acting on the answer is just what follows a gate, and the name is an input to the start, not a step of its own. It runs before the effort exists, so there's no effort log yet to hold it. It ships with the framework as a JSON file, and main reads it through `flow.sh` like any other flow. Its last step writes `effort.started`, and from then on the effort's own log holds everything.

```json
{
  "kind": "fixed",
  "name": "open-effort",
  "goal": "Open an effort for work the human agrees is one",
  "done_when": { "event": "effort.started" },
  "steps": [
    {
      "id": 1,
      "do": "Offer an effort, with the reasons from the situation",
      "uses": { "gate": "effort-offer" },
      "done_when": { "event": "gate.effort-offer.answered" }
    },
    {
      "id": 2,
      "do": "On a yes: name the effort from the request (up to three words) and start it",
      "uses": { "piece": "effort.sh start" },
      "done_when": { "event": "effort.started" }
    }
  ]
}
```

Resuming an existing effort (find it, match it, act on what was found) is a second fixed flow of the same shape, and it ends the same way: an open effort.

## 2. The effort is a lifecycle, not a flow

An effort's life isn't a sequence of steps. It is a set of states (open, paused, completed, dropped) and the moves allowed between them (pause, resume, complete, drop, reopen). That's a state machine, and it's already a piece: `effort.sh` writes each move as an event and refuses a move the state doesn't allow. So `effort.started` carries no flow:

```json
{
  "type": "effort.started",
  "seq": 1,
  "at": "2026-11-20T10:02:11Z",
  "by": "effort.sh",
  "claude_session_id": "3b15192d-0617-427a-be22-290da7f067db",
  "body": { "name": "notes-search" }
}
```

| State | Moves allowed | Each move is |
|---|---|---|
| open | pause, complete, drop | `effort.sh pause`, `complete`, `drop` |
| paused | resume, complete, drop | `effort.sh` the same way |
| completed, dropped | reopen | `effort.sh reopen` |

Main makes a move when the human asks, or offers one at a gate when the work looks done or the human moves on. What happens inside an open effort is dynamic flows, one per goal, starting with the context.

**So there are three shapes:** fixed flows (opening or resuming an effort: shipped with the framework, never negotiated), the lifecycle (states and moves, enforced by `effort.sh`), and dynamic flows (agreed per goal, below).

## 3. A dynamic flow: building the context

Main proposes the steps from the hows it knows and from flows that worked before. You agree, change or replace them at the `flow-agree` gate, and the result is an event:

```json
{
  "type": "flow.agreed",
  "seq": 4,
  "at": "2026-11-20T10:05:40Z",
  "by": "flow.sh",
  "claude_session_id": "3b15192d-0617-427a-be22-290da7f067db",
  "gate": 3,
  "body": {
    "kind": "dynamic",
    "goal": "Know what we're building and why",
    "done_when": { "event": "context.cut" },
    "steps": [
      {
        "id": 1,
        "do": "Investigate the repo and the ticket",
        "uses": { "how": "how-discovery" },
        "done_when": { "event": "discovery.noted" }
      },
      {
        "id": 2,
        "do": "Draft the spec",
        "uses": { "how": "how-spec" },
        "done_when": { "event": "spec.drafted" }
      },
      {
        "id": 3,
        "do": "Approve the spec",
        "uses": { "gate": "spec-approval" },
        "done_when": { "event": "gate.spec-approval.answered", "answer": "approve" }
      },
      {
        "id": 4,
        "do": "Lock the context version",
        "uses": { "piece": "context.sh freeze" },
        "done_when": { "event": "context.cut" }
      }
    ]
  }
}
```

- `seq` 4 is this flow's id: every change points at it.
- `gate` points at your answer that agreed it.

## 4. Changing it on the go

Halfway through, you say "let's do a grill before the spec". Your request is the agreement, so main records it with no extra gate:

```json
{
  "type": "flow.changed",
  "seq": 7,
  "at": "2026-11-20T10:21:03Z",
  "by": "flow.sh",
  "claude_session_id": "3b15192d-0617-427a-be22-290da7f067db",
  "flow": 4,
  "body": {
    "reason": "The human asked for a grill before the spec",
    "changes": [
      {
        "add": {
          "id": 5,
          "do": "Grill the human on goal and scope",
          "uses": { "how": "how-grill" },
          "done_when": { "event": "grill.completed" }
        },
        "before": 2
      }
    ]
  }
}
```

- The new step gets the next free id (5), even though it runs second: ids are never reused or renumbered.
- `flow.agreed` #4 is never edited. A `flow.changed` that points at a `fixed` flow is refused.
- The other changes have the same shape: `{"skip": 3, "reason": "…"}` and `{"move": 5, "before": 1}`.

## 5. What main sees

`flow.sh show --effort <folder>` replays the events and prints one card:

```
Building the context · notes-search
  ✓ 1  Investigate the repo and the ticket
  ✓ 5  Grill the human on goal and scope      (added by you)
  → 2  Draft the spec
    3  Approve the spec
    4  Lock the context version
```

Main reads where it is from that card, computed from the log, never from memory or scrollback.
