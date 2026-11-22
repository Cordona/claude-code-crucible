# Spec: crucible-dynamic-flow

The human and main agree a flow for any goal: building the context, building, testing, or any kind of review. They change it on the go, and can always see what's done and what's left. The flow is a tracked agreement, not an engine: it never runs steps and never enforces their order. The pieces it names do the work and keep their own invariants.

**Home:** `new-rewrite/framework/core/main-thread/crucible-dynamic-flow/`

## 1. The node

```json
{ "id": 2, "do": "Grill the open goal", "uses": "crucible-grill", "done_when": { "event": "grill.ended" } }
```

| Field | Holds |
|---|---|
| `id` | A whole number, unique in the flow, never reused. Required |
| `do` | One line: what the step achieves. Required |
| `uses` | Optional. The skill or piece that does the work, for the human's information; nothing resolves it |
| `done_when` | Required, and always a yes/no. Either `{"event": "<type>", "match"?: {<top-level body field>: <value>}}`, where the event is there or not (plain equality on top-level body fields), or `{"criteria": "<one line, true or false>", "by"?: "human"}`, judged by main, or by the human with `"by": "human"` |

**The preference order:** an event, then a criterion main verifies, then a criterion the human verifies. A `done_when` names a piece's outcome event, never a gate answer. There are no commands in the JSON.

## 2. The flow

```json
{
  "goal": "Share one understanding of what the prune work must achieve",
  "done_when": { "criteria": "the human says we share one understanding of the goal", "by": "human" },
  "steps": [
    { "id": 1, "do": "Find out what the work is about", "done_when": { "criteria": "the human confirmed the goal and what must not break", "by": "human" } },
    { "id": 2, "do": "Grill the open goal", "uses": "crucible-grill", "done_when": { "event": "grill.ended" } }
  ]
}
```

- **The flow's own `done_when`** has the same shape as a step's. "Every step done" says the plan was carried out; the flow's criterion says the goal was reached.
- **When every step is done but the criterion is false,** the flow can't end `done`: steps are added, or it ends `dropped`, with the reason.

## 3. The events

Each event carries the usual envelope. A flow's id is the seq of its `flow.agreed`, and the effort's folder plus that seq names a flow without doubt.

| Event | Body |
|---|---|
| `flow.agreed` | `{goal, done_when, steps}`. Never edited |
| `flow.changed` | `{flow, reason, ops}`. Each op is one of: `{"add": <node>, "before"?: <id>}` (with no `before`, it's appended), `{"skip": <id>}`, `{"move": <id>, "before": <id>}`, `{"reopen": <id>}` (a done or skipped step goes back to not done), `{"revise": {"step"?: <id>, "done_when": <done_when>}}` (an open step's check, or with no `step` the flow's own, is replaced; evidence written before the revise still counts). One reason per change; two reasons make two events |
| `flow.step.done` | `{flow, step, kind, event?, evidence?}` |
| `flow.ended` | `{flow, outcome, kind?, event?, evidence?, words?}` |

- **`kind` is set by the script from the step's `done_when`,** never passed by main: `event`, `main` or `human`.
- **With `kind: event`,** `event` is the seq of the matching event.
- **Otherwise,** `evidence` is one line: how main verified the criterion, or the human's words.
- **`flow.ended`:** `outcome: done` carries the flow-level evidence the same way, and `outcome: dropped` carries `words`, the human's reason.

| Field | Read by |
|---|---|
| `goal` | `flow-show.sh`, the hook's line |
| `done_when` (flow) | `flow-end.sh` |
| `steps[]`, `ops` | `flow-show.sh`, `flow-step-done.sh`, `flow-change.sh` (to replay the current steps) |
| `match` | `flow-step-done.sh`: plain equality on top-level body fields |
| `flow` | every flow script, the hook |
| `reason` | `flow-show.sh` (on request), audit |
| `step` | `flow-show.sh`, the hook |
| `kind` | `flow-show.sh` (its mark: checked, claimed by main, or confirmed by the human) |
| `event` | `flow-step-done.sh` (one event, one step), `flow-show.sh` |
| `evidence`, `words`, `outcome` | `flow-show.sh` (on request), audit |

## 4. The rules the scripts enforce

- **The shape:** every node and the flow have a `done_when` of one of the two kinds. A criterion is one non-empty line; whether it's truly yes/no is judged at the gate.
- **An event step's mark** needs a matching event after the flow's seq. If a reopen happened, the event must be newer than the reopen.
- **Each event is evidence for at most one step** across the whole effort. Main passes the seq when several fit. The flow-level check doesn't count as a claim.
- **A criterion step's mark** needs an evidence line.
- **Order is advisory:** any open step can be marked done, and several can be open at once.
- **`done` needs every step done or skipped,** plus the flow's own `done_when` met: the event checked by the script, or the evidence line for a criterion. **`dropped`** needs the human's words.
- **Writes refuse unless the effort is open.**

## 5. The pieces

| Script | Job |
|---|---|
| `flow-agree.sh --effort --file FLOW.json` | Checks the shape, writes `flow.agreed`, prints the flow id |
| `flow-change.sh --flow --file OPS.json --reason` | Writes `flow.changed` |
| `flow-step-done.sh --flow --step [--event SEQ] [--evidence LINE]` | Checks the evidence, writes `flow.step.done` |
| `flow-end.sh --flow --outcome done\|dropped [--evidence LINE] [--words LINE]` | Writes `flow.ended` |
| `flow-show.sh --flow \| --effort` | Replays the events and prints each open flow: done (with its mark), next, left, and open steps whose evidence is waiting unmarked |
| `events/flow.*.jq` | One rule per event type, applied by `event-write.sh` |

A flow is named by `--flow <effort folder>:<seq>`.

## 6. The Stop hook: `hooks/stop/remind-flow-position.sh`

- **Which flows it looks at:** the open flows in open efforts that this session has written an event to.
- **When it speaks:** only on a certain signal, and once per signal:
  - an open step's evidence is waiting unmarked;
  - the position changed since the hook last spoke for that flow in this session;
  - every step is done or skipped and the flow is still open.

  Otherwise it stays silent.
- **What it says:** one line per flow that has a signal, for example: "Flow 4 'Share one understanding…': step 2 'Grill the open goal' is next (1 of 2 done). Go on, mark it, or wait for what's running."
- **What it remembers:** the last position spoken, per session and flow. A new session therefore speaks each open flow once, at its first stop there.
- **Its contract:** it never blocks twice in a row (`stop_hook_active` lets the stop through), and a hook fault lets the stop through.

## 7. The how: `crucible-dynamic-flow/SKILL.md`, about 100 words, part of this build

- When a flow is worth it. Small goals get none.
- Propose a flow from the skills and pieces main knows, agreeing it at a gate.
- Routine work is one click on the recommended flow.
- Each `done_when` is a yes/no.
- Mark steps as they finish.
- Record a change when the human asks for one.
- Look at the open flows when returning to an effort.
- One example flow.

## 8. Not yet

- **Gate answer events:** until they exist, `flow-agree.sh` can't prove the human agreed. It's the same known gap as starting an effort.
- **The first follow-up after the live run:** `effort-close.sh` refuses while a flow is open, naming it, unless the human says to close anyway.
- **Nested flows:** a step can already name another flow's `flow.ended`.
- **Checking pieces** for mechanical criteria, built when a live run shows a claim can't be trusted.
- **No staleness timer and no repeated nag.**

## 9. The first live run

The flow in §2, which today's pieces can finish: a human-confirmed criterion, `grill.ended`, and the flow's own human-confirmed criterion. Run it twice, once accepted in one click and once changed mid-flow. Watch:
- all three kinds of evidence;
- the hook's signals;
- `flow.changed`;
- the gate's Stop hook and the flow's Stop hook in one session.

## Decided, and why

- **Explicit marks with checked evidence, not derived progress:** derived progress silently credits the wrong step when event types repeat.
- **Order is advisory, and fan-out lives inside pieces:** that's what lets one node shape fit every flow.
- **The hook speaks only on a certain signal:** a reminder at every stop would be noise on the most frequent path, where main is rightly waiting for the human.

The earlier drafts and the review rounds are in `history/`.

## Stuck steps (decided with Fable, 2026-11-21)

- **A wrong check:** the `revise` op in `flow.changed`. `{"revise": {"step": <id>, "done_when": DW}}` replaces an open step's check; with no `step`, it replaces the flow's own. It doesn't reset the evidence age. A done step is reopened first. The owner approved and it is built.
- **A met check that main never marks:** nothing new. Order is advisory, so the next mark moves the position and the hook names the step still open. `flow-end.sh` refuses `done` while a step is open, so the track lags but never lies. The live run counts late or missing criteria marks. If they're frequent, the first candidate is one line of flow position when the human's next message arrives, not a Stop signal.
- **A mark refused or failing when it shouldn't:** a framework bug. Main shows the reason. The options are to fix it now, to leave the step open and go on, or to drop the flow. Skip is only a last resort, in the human's words. There's no prose for this case.

## Agreement proven by a recorded yes (owner + Fable, 2026-11-21)

- **`flow-agree.sh` requires a `gate.answered`** with record `flow-agree`, its subject the flow file's sha256, and `accepted: true`. One acceptance agrees one flow. A typed answer is not acceptance: main changes the file, the sha changes, and it asks again.
- **The card for that gate is rendered from the flow file** by a new `flow-show.sh` mode, showing the goal, each step and its check in the track's layout. The human then sees exactly what the sha proves.
- **`flow.changed` needs no recorded yes for now.** A change the human asks for: their words are the agreement. A change main wants: an ordinary gate, not recorded. The live run counts whether main ever skipped or revised on its own. If it did, require a recorded yes for `skip` and `revise` only.
- **The known limit:** a change is main's claim about what the human asked, always visible in the track with its reason. Only the first agreement is proven.
- **The order:** the flow's live run now needs the gate answer events first.
