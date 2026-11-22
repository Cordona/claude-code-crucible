# crucible-dynamic-flow: a design for review

The goal: you and main agree a flow for any goal (build the context, build, test, review of any kind), change it on the go, and always know where you are. The machinery should be simple and still hard to slip past.

## 1. The node: one shape for every flow

```json
{ "id": 3, "do": "Draft the spec with the human", "uses": "crucible-spec", "done_when": { "event": "gate.answered", "match": { "record": "spec-approval" } } }
```

| Field | Holds | Required |
|---|---|---|
| `id` | A whole number, unique in the flow, never reused | yes |
| `do` | One line: what this step achieves | yes |
| `uses` | What does the work: a skill, a how or a script, named in one word or path. It's informative: nothing resolves it | yes |
| `done_when` | The evidence the step is done: `{"event": "<type>"}`, optionally with `"match": {<body field>: <value>}`. With no event that fits (say, the human checks something by hand): `{"human": true}` | yes |

That's the whole node. It has no branches, no conditions and no next pointers: the order is the list's order, and a change is a new event. It fits any flow, because what's specific to the case lives in `do`, `uses` and the event named, never in the shape.

A flow:

```json
{ "goal": "Know what we're building and why", "steps": [
  { "id": 1, "do": "Find out what the effort is about", "uses": "crucible-discovery", "done_when": { "human": true } },
  { "id": 2, "do": "Grill the open goal", "uses": "crucible-grill", "done_when": { "event": "grill.ended" } },
  { "id": 3, "do": "Agree the spec", "uses": "crucible-spec", "done_when": { "event": "gate.answered", "match": { "record": "spec-approval" } } }
] }
```

## 2. The events (all in the effort's log; the flow's id is the seq of its `flow.agreed`)

| Event | Written by | Body |
|---|---|---|
| `flow.agreed` | `flow-agree.sh` | `{goal, steps}`. Never edited |
| `flow.changed` | `flow-change.sh` | `{flow, reason, ops}`. Each op is one of: `add` (a new node, `before` an id), `skip` (an id), `move` (an id, `before` an id), `reopen` (an id: back to not done) |
| `flow.step.done` | `flow-step-done.sh` | `{flow, step, evidence}`. `evidence` is the seq of the matching event, or the human's words for `{"human": true}` |
| `flow.ended` | `flow-end.sh` | `{flow, outcome: done\|dropped, words}`. A flow ends `done` only when every step is done or skipped |

**Completion is checked, not trusted.** `flow-step-done.sh` refuses unless the evidence exists. For an event step, there must be a matching event after the flow's seq; for a human step, there must be words. So main marks progress explicitly, a single uniform action, but can't mark a step done without its evidence.

## 3. The pieces

- `flow-agree.sh --effort --file FLOW.json`: validates the shape, writes `flow.agreed`, and prints the flow id.
- `flow-change.sh --flow --file OPS.json --reason`: writes `flow.changed`.
- `flow-step-done.sh --flow --step [--words]`: checks the evidence and writes `flow.step.done`.
- `flow-end.sh --flow --outcome --words`: writes `flow.ended`.
- `flow-show.sh --flow | --effort`: replays the events and prints each open flow: done, next, and left. This is the tracking.
- `events/flow.*.jq`: one rule per event type, applied by `event-write.sh`.

## 4. Staying on the flow: the Stop hook

`hooks/stop/remind-flow-position.sh`. When main's turn ends and this session has an open flow whose next step isn't done, the hook sends main back once with one line per open flow:

> Flow 4 "Know what we're building": step 2 "Grill the open goal" is next (1 of 3 done). Go on with it, mark it done, or end your turn with a question to the human.

- **Once per stop:** with `stop_hook_active` the stop goes through. Main is reminded, never trapped.
- **This is what fixed Gamma's drops:** the driver reached the end in 5 of 5 runs, at about +5% cost. Unlike Gamma's driver, it doesn't hand out steps; it only says where you are.
- **Which flows:** the open flows in open efforts with an event from this session. Several flows at once are fine: each gets its line.

## 5. What's left to main and the human (no machinery)

- Proposing a flow from the hows it knows, and agreeing it at a gate.
- Changing it when the human asks: their words are the agreement.
- Running each step with its how.
- Going back: `reopen` a step when its evidence no longer holds (say, a revised spec).

## 6. Open questions

1. Explicit `flow.step.done` with checked evidence, or progress derived from events alone? Explicit is one uniform action and works for human steps; derived needs no action and can't be forgotten.
2. Is a Stop hook reminder once per stop the right strength? It costs one short continuation each time main pauses for the human mid-flow.
3. Nested flows, a step that is a whole sub-flow: left out for now. A step's `done_when` could be `flow.ended` of another flow later.

## 7. After Fable's review (2026-11-21): approved with changes

- **The node stays as it is:** `{id, do, uses, done_when}`.
- **Three rules that make it universal:**
  - **A. Order is advisory.** The flow never enforces order. Several steps may be open at once, and `flow-step-done.sh` accepts any order. Unsafe orders are refused by the pieces (dispatch without an approved plan), never by the flow. The flow is a tracked agreement, not an engine.
  - **B. Fan-out lives inside a step's piece.** Seats, lenses, review threads and fix rounds belong to the piece, which writes one closing event that `done_when` names. The contract on every future piece: a flow-sized job writes one closing event.
  - **C. `done_when` names a piece's outcome event, never a gate answer.** For example, `spec-approve.sh`'s fact, not `gate.answered`. So the flow doesn't depend on the gate answer events.
- **Completion is explicit,** with checked evidence, because it fails the safe way. Each event can be evidence for one step only, across the whole effort; main passes the seq when several fit. `flow-show.sh` also lists open steps whose evidence is waiting unmarked.
- **After a `reopen`,** only evidence newer than the reopen counts.
- **The Stop hook speaks only on a certain signal,** once each:
  - evidence waits unmarked for an open step;
  - the position changed since the hook last spoke for that flow;
  - every step is done or skipped and the flow is still open.

  Otherwise it stays silent. It keeps one remembered value per flow (the last position spoken), and its line allows waiting ("or wait for what's running").
- **Nested flows come later,** and nothing needs building for them: a step can name another flow's `flow.ended`.
- **`{human: true}` is the last resort.** Prefer an event wherever a piece writes one.
- **The how:** judgment only. Propose a flow from the hows main knows. Routine work is one click on the recommended flow, and small goals get no flow at all.
- **Watch in the live run:** the gate and flow Stop hooks speaking in the same stop.
- **For later:** an open flow as the generic "open work" sign for the close check.
- **Next:** build it, then a first live run of the context flow, once accepted in one click and once changed mid-flow.

## 8. Every node is verifiable (owner, 2026-11-21)

- **`done_when` is always a yes or no:**
  - `{"event": "<type>", "match"?: {...}}`: the event is there or it isn't, and the script checks it;
  - `{"criteria": "<one short yes/no check>", "by"?: "human"}`: a criterion that is true or false, such as "all tests green" or "the login works on staging", judged by main, or by the human with `"by": "human"`.
- **`{"human": true}` is replaced** by a criterion with `"by": "human"`.
- **A criteria step's mark needs evidence:** `flow-step-done.sh --evidence "<how it was verified>"`, stored in `flow.step.done`. For `by: human`, the evidence is the human's words.
- **No commands in the flow JSON.** A mechanical criterion becomes a piece that checks it and writes an event.
- **The order of preference:** an event, then a criterion main verifies, then a criterion the human verifies.
- **The flow itself is verifiable too:** `{"goal": "<what it's about>", "done_when": {"criteria": "<yes/no>"}, "steps": [...]}`. `flow-end.sh --outcome done` needs every step done or skipped, plus evidence for the flow's own criterion.
- **Whether a criterion is truly yes/no** is judged when the flow is agreed, at the gate. The script only checks that it's one non-empty line.

## 9. After Fable's review of §8 (2026-11-21): approved with three changes

1. **The track shows how each done step was established:** checked by the script, claimed by main, or confirmed by the human. One mark per kind, with the evidence line on request.
2. **The flow's own `done_when` takes the same shape as a step's:** an event or a criterion, with the event preferred. An event is checked by `flow-end.sh` itself. The "one event, one step" rule doesn't count the flow-level check as a claim. When every step is done but the flow's criterion is false, the flow can't end `done`: steps are added, or it ends `dropped` with the reason.
3. **The event bodies are previewed for the owner first:** `specs/dynamic-flow-events.md`.

**Fable's answers:**
- **Main judging criteria with recorded evidence is acceptable.** The invariants stay in the pieces' refusals.
- **`flow-agree.sh` checks only "one non-empty line".** Whether a criterion is truly yes/no is judged at the gate, helped by one good example in the how.
- **The flow-level `done_when` is worth it:** "every step done" says the plan was carried out; the criterion says the goal was reached.
- **Caution:** don't build checking pieces ahead of need. "Tests green" stays a criterion main verifies until a live run shows the claim can't be trusted.

**Status:** the design is cleared by Fable. Building waits for the owner's go, and the event shapes wait for the owner's approval.
