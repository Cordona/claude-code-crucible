# Spec: crucible-adaptive-flow

Main and the human agree a flow: the steps toward a goal inside an effort, each a step that a piece of the framework declares and each ended by that piece's own event. Then they change it on the go and see what is done and left. A flow is a tracked agreement, not an engine: it never runs a step or enforces order. It can't carry free text, criteria or acceptance criteria.

**Home:** `new-rewrite/framework/core/main-thread/crucible-adaptive-flow/`

## The pieces

| Piece | Its one job |
|---|---|
| `<component>/flow-step.json` (in each component that offers steps) | The steps that component declares |
| `scripts/main/flow-candidates.sh [--stage NAME] \| --stages` | Lists the declared steps, or the stage names with their counts. Reads only. |
| `scripts/main/flow-card.sh --file` | Prints the card for agreeing a flow not yet agreed, each step resolved from the catalogue. Reads only. |
| `scripts/main/flow-agree.sh --effort --file` | Writes `flow.agreed` once every step is declared and the human's recorded yes is found; prints the flow's name |
| `scripts/main/flow-change.sh --flow --file --reason` | Writes `flow.changed`: one array of ops, one reason |
| `scripts/main/flow-step-done.sh --flow --step [--event]` | Writes `flow.step.done` once the step's event is checked |
| `scripts/main/flow-end.sh --flow --outcome done\|dropped` | Writes `flow.ended` |
| `scripts/main/flow-show.sh --flow [--all] \| --effort` | Replays the events and prints each flow's track, what is next, and whether it can end. Reads only. |
| `scripts/internal/open-work.sh --effort` | One line per open flow, for `effort-close.sh`. Reads only. |
| `scripts/lib/catalogue.sh`, `catalogue.jq` | The one reader of the catalogue, and its shape rules |
| `scripts/lib/flow.sh`, `flow-replay.jq` | Shared shell, and the one home of the flow's shape checks and its replay |
| `events/flow.*.jq` | One rule per event type, applied by `event-write.sh` |
| `hooks/stop/remind-flow-position.sh` | Tells main where it stands, only on a signal |

A flow is named `<effort folder>:<seq>`, the seq of its `flow.agreed`. Every write refuses unless the effort is open.

## The catalogue

A component that offers steps has a `flow-step.json` next to its `SKILL.md`: a JSON array of entries, written in this order:

| Field | Rule | Read by |
|---|---|---|
| `name` | Lowercase letters, digits and `-`, unique in its file. With the component's folder name it forms the step's key, `<component>/<name>`. | the scripts that resolve keys, the scan's output |
| `stage` | A list of one or more names, of the same form | `flow-candidates.sh --stage` and `--stages` only |
| `does` | One line: what the step achieves | the card, the track, main |
| `propose_when` | One line: when the step is worth proposing | main |
| `ends_with` | `{event, match?}`: the event that ends the step. The event type must have exactly one rule, and is never `gate.answered`. `match` is plain equality on top-level body fields. | `flow-step-done.sh` and the rules, once copied into the flow |
| `skills` | A list of the skills main loads for the step, each installed beside the component (a folder holding a `SKILL.md`) | main, the card |

There is no order, no `optional` and no criterion.

**The scan** reads every `flow-step.json` that `beside.sh` finds (crucible-events' helper). Installed, that is every linked component, core and domain alike; by real path, core's own folder. An invalid file or entry is left out, named on stderr one line per problem, and the scan still exits 0: a step that isn't listed can't be agreed, so the failure is safe and one broken file never blocks every flow. Its listing is sorted by key.

**Stages** are filter labels, never an order. No script holds a list of stages or checks their sequence. Core owns only `prepare`, and a domain declares its own. Core's prose names no other stage.

**The first catalogue:**

| Key | Ends with | Stage | Skills |
|---|---|---|---|
| `crucible-context/build-context` | `context.cut` | prepare | crucible-discovery, crucible-context |
| `crucible-grill/grill` | `grill.ended` | prepare | crucible-grill |
| `crucible-spec/specify` | `spec.approved` | prepare | crucible-spec |

Discovery has no step of its own: building the context is the step, and discovery is how it is done. The context step naming `crucible-discovery` in `skills` is a known mention of one piece by another, not a pattern to copy.

## The flow

The flow file main writes names steps and never describes them:

```json
{ "goal": "<one line>", "steps": [ { "id": 1, "step": "<component>/<name>" }, ... ] }
```

- `id` is a whole number from 1, unique and never reused, even after a skip.
- The same key may appear twice, under two ids, for example a second cut. Each occurrence needs its own event.
- A flow has no check of its own. It is done when every step is done or skipped.
- **Order is advisory.** Any open step may be marked, in any order, and several can be open at once.

`flow-agree.sh` and `flow-change.sh` resolve each key through the catalogue and copy the entry's `does`, `skills` and `ends_with` into the event, so the event reads the same later whatever the catalogue says by then. A key that isn't declared is refused. A key whose entry the scan left out is refused with the scan's reason.

## The events

| Event | Body | Read by |
|---|---|---|
| `flow.agreed` | `{goal, steps: [{id, step, does, skills, ends_with}], answer}` | `goal`: show, open-work, the hook; `steps`: the replay; `answer`: its own rule (used once) |
| `flow.changed` | `{flow, reason, ops}` | `flow`, `ops`: the replay; `reason`: audit |
| `flow.step.done` | `{flow, step, event}` | `step`: the replay and show's mark; `event`: the used-once check and show `--all` |
| `flow.ended` | `{flow, outcome, words?}` | `flow`: the replay and the open-flow lists; the rest: audit |

- **The ops,** applied in order:
  - `{add: {id, step}, before?: ID}`: a declared step, resolved and copied like `flow-agree.sh` does, appended when there is no `before`;
  - `{skip: ID}`: open steps only;
  - `{move: ID, before: ID}`;
  - `{reopen: ID}`: done or skipped steps.

  The agreed flow is never edited.
- **One event proves one step** across the whole effort. Without `--event`, the one waiting event is taken; with several waiting, they are named and main picks.
- **A step's event may be older than the flow** (work done before the flow was agreed), but never older than the step's latest reopen.
- **`done`** needs every step done or skipped. **`dropped`** needs the human's words.

## Agreeing a flow

1. Main runs the scan, writes the flow file, and shows the card from `flow-card.sh`: the goal, then each step's `does`, its skills and its ending event.
2. The human answers at a recorded gate: record `flow-agree`, subject the file's sha256.
3. `flow-agree.sh` checks the shape, resolves every key, then asks the gate's reader, `gate-answer.sh`, for the newest answer on that record and subject. A later no cancels an earlier yes. With no accepting answer it refuses.
4. The answer's seq goes into the body. The `flow.agreed` rule checks the shape, that `answer` is a number, and that no earlier flow used it: one yes agrees one flow. A changed file has a new sha and needs a new yes.

A change needs no recorded yes yet. It will once dispatch enforces flows.

## The Stop hook

- **Which flows:** the open flows of open efforts holding an event this session wrote. It finds them with a cheap search for the bare session id in the event files, then a real test on `claude_session_id` through `events-read.sh`.
- **When it speaks:** only on a signal: an open step's event is waiting unmarked; the position moved (the next step, or how many are done); every step is done or skipped and the flow is still open. It remembers the last position spoken per session and flow, so each change speaks once and a new session speaks each open flow once.
- **What it says:** one line per flow with a signal, warning when a waiting event also fits another open step.
- **Its contract:** a subagent's stop passes, and a fault lets the stop through, a damaged log included: an effort whose events can't be read whole is skipped in silence. It never blocks; it adds context. Its memory of the last position spoken is its only loop guard.

## Decided, and why

- **Steps only from the catalogue, enforced by the scripts.** In live run 5, a flow of free-text steps copied the spec's acceptance criteria into a second, unsealed contract and main marked them itself.
- **Every step ends in its own piece's event.** A criterion is a claim. The human's judgement becomes a step only through a piece that asks at its gate and writes its own fact, as `spec-approve.sh` writes `spec.approved`. A raw `gate.answered` is refused because only the gate's reader knows which answer counts.
- **Key plus a copied entry:** a sealed event must not change meaning when a `flow-step.json` is edited.
- **Stages are a filter only:** an order in the catalogue would bring back the fixed pipeline.
- **A checked `skills` list:** a field nothing checks goes stale silently. The check is exactly that each named skill is installed beside the component; nothing loads skills for main.
- **Explicit marks with checked evidence, not derived progress:** derived progress silently credits the wrong step when event types repeat.
- **Agreement proven by a recorded yes on the file's sha:** the human sees exactly what the sha proves.
- **The rules don't read gate answers, and the card is its own script:** one job per piece.
- **Changes are new events:** a record acted on is sealed.
- **The hook speaks only on a signal:** a reminder at every stop is noise when main is rightly waiting for the human.
- **`open-work.sh`:** effort-close names no component; each reports its own open work.

## Known limits

- The hook looks at every effort at each stop until pruning exists.
- A change is main's claim about what the human asked, visible with its reason, until dispatch requires a recorded yes for it.
- Work that no piece ends with an event can't be a flow step. Until dispatch brings the domain's build steps, a build main writes itself has no flow.
- A misspelt stage name gives a stage with one step in `--stages`; nothing else checks it.
- A met step main never marks leaves the track lagging. It never lies, since `done` refuses while a step is open.
