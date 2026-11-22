# Spec: crucible-dynamic-flow

Main and the human agree the steps toward a goal inside an effort, change them on the go, and see what is done and left. A flow is a tracked agreement, not an engine: it never runs a step or enforces order.

**Home:** `new-rewrite/framework/core/main-thread/crucible-dynamic-flow/`

## The pieces

| Piece | Its one job |
|---|---|
| `scripts/flow-card.sh --file` | Prints the card for agreeing a flow not yet agreed; refuses a wrong shape. Reads only |
| `scripts/flow-agree.sh --effort --file` | Writes `flow.agreed` once the shape is checked and the human's recorded yes is found; prints the flow's name |
| `scripts/flow-change.sh --flow --file --reason` | Writes `flow.changed`: one array of ops, one reason |
| `scripts/flow-step-done.sh --flow --step [--event \| --evidence]` | Writes `flow.step.done` once the evidence is checked |
| `scripts/flow-end.sh --flow --outcome done\|dropped` | Writes `flow.ended` |
| `scripts/flow-show.sh --flow [--all] \| --effort` | Replays the events and prints each flow's track, what is next, and whether it can end. Reads only |
| `scripts/open-work.sh --effort` | One line per open flow, for `effort-close.sh`. Reads only |
| `scripts/lib/flow.sh`, `flow-replay.jq` | Shared shell, and the one home of the shape checks and the replay |
| `events/flow.*.jq` | One rule per event type, applied by `event-write.sh` |
| `hooks/stop/remind-flow-position.sh` | Tells main where it stands, only on a signal |

A flow is named `<effort folder>:<seq>`, the seq of its `flow.agreed`. Every write refuses unless the effort is open.

## The flow

```json
{ "goal": "<one line>", "done_when": DONE_WHEN, "steps": [NODE, ...] }
```

- **A node** is `{id, do, uses?, done_when}`. `id` is a whole number from 1, unique and never reused, even after a skip. `do` is one line. `uses` is one line naming the skill or piece, for the human only; nothing resolves it.
- **A `done_when`** is a yes or no, one of two kinds:
  - `{event: "<type>", match?: {<body field>: <value>}}`: the event exists or not; `match` is plain equality on top-level body fields.
  - `{criteria: "<one line>", by?: "human"}`: judged by main, or by the human with `by: "human"`.
- **The flow's own `done_when`** has the same shape.
- **Order is advisory.** Any open step may be marked, in any order; several can be open at once.

## The events

| Event | Body | Read by |
|---|---|---|
| `flow.agreed` | `{goal, done_when, steps, answer}` | `goal`: show, open-work, the hook; `done_when`, `steps`: the replay; `answer`: its own rule (used once) |
| `flow.changed` | `{flow, reason, ops}` | `flow`, `ops`: the replay; `reason`: audit |
| `flow.step.done` | `{flow, step, kind, event?, evidence?}` | `step`, `kind`: the replay, show's mark; `event`: used-once check; `evidence`: show `--all` |
| `flow.ended` | `{flow, outcome, kind?, event?, evidence?, words?}` | `flow`: the replay, open-flow lists; the rest: audit |

- **`kind`** is set by the script from the check, never passed: `event`, `main` or `human`. With `event`, the body holds the proving seq; otherwise one line of `evidence`.
- **The ops**, applied in order: `{add: NODE, before?: ID}` (appended without `before`), `{skip: ID}` (open steps only), `{move: ID, before: ID}`, `{reopen: ID}` (done or skipped steps), `{revise: {step?: ID, done_when}}` (an open step's check, or with no `step` the flow's own). The agreed flow is never edited.
- **One event proves one step** across the whole effort. Without `--event`, the one waiting event is taken; with several, they are named and main picks.
- **An event step's evidence must be newer than the step's start:** the flow's seq, the `add` that created it, or its latest `reopen`. After a reopen, only newer evidence counts. A `revise` keeps the age: evidence written before it still counts.
- **`done`** needs every step done or skipped, and the flow's own check met: its event after the flow started (by default the newest one), or one line of evidence from main or the human. **`dropped`** needs the human's words.

## Agreeing a flow

1. Main writes the flow file and shows the card from `flow-card.sh`: goal, each step and its check, the flow's own check.
2. The human answers at a recorded gate: record `flow-agree`, subject the file's sha256.
3. `flow-agree.sh` checks the shape, then asks the gate's reader, `gate-answer.sh`, for the newest answer on that record and subject. A later no cancels an earlier yes. With no accepting answer it refuses.
4. The answer's seq goes into the body. The `flow.agreed` rule checks the shape, that `answer` is a number, and that no earlier flow used it: one yes agrees one flow. A changed file has a new sha and needs a new yes.

A change needs no recorded yes: the human's words are the agreement.

## The Stop hook

- **Which flows:** the open flows of open efforts holding an event this session wrote. It finds them by a cheap search for the bare session id in the event files, then a real test on `claude_session_id` through `events-read.sh`.
- **When it speaks:** only on a signal: an open step's evidence is waiting unmarked; the position moved (the next step, or how many are done); every step is done or skipped and the flow is still open. It remembers the last position spoken per session and flow, so each change speaks once and a new session speaks each open flow once.
- **What it says:** one line per flow with a signal, warning when a waiting event also fits another open step.
- **Its contract:** a subagent's stop passes, and a fault lets the stop through. It never blocks; it adds context. Its memory of the last position spoken is its only loop guard, so it also speaks when another hook already continued the turn, as every gate does; a second stop in the same turn finds the same position and stays silent.

## Decided, and why

- **A done_when's event is checked only as one line, not by its form:** how types are named belongs to crucible-events alone. A name that is no real type simply never gets evidence, which the track shows.
- **Explicit marks with checked evidence, not derived progress:** derived progress silently credits the wrong step when event types repeat.
- **Order advisory, fan-out inside pieces:** one node shape fits every flow.
- **Agreement proven by a recorded yes on the file's sha:** the human sees exactly what the sha proves; a typed answer is not acceptance.
- **The rule doesn't read gate answers, and the card is its own script:** one job per piece.
- **Changes are new events:** a record acted on is sealed.
- **The hook speaks only on a signal:** a reminder at every stop is noise where main is rightly waiting for the human.
- **`open-work.sh`:** effort-close names no component; each reports its own open work.

## Known limits

- The hook looks at every effort at each stop until pruning exists.
- A change is main's claim about what the human asked, visible with its reason; only the first agreement is proven.
- A criteria mark is main's or the human's word, not a check.
- A met check main never marks leaves the track lagging; it never lies, since `done` refuses while a step is open.
