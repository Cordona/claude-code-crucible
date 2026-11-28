# The step catalogue: design

> Built on 2026-11-22 with the owner's renames: the file is `flow-step.json`; its fields are name, stage, does (was do), propose_when (was fits), ends_with (was done_when, in flow events too) and skills (was uses, now a checked list). `specs/crucible-dynamic-flow.md` describes what is built.

The owner asked for this design on 2026-11-22. Fable reviews it, and nothing is built before the owner's go. The decisions it builds on are in HANDOFF, "Where things stand", in the Next bullet.

## 1. Why

In run 5, main's build flow (events 8–12) copied the spec's acceptance criteria into five free-text steps and then marked four of them itself. That gave a second, unsealed contract, approved at a gate and changeable with `flow-change.sh`.

The repair is that a flow is a sequence of the framework's floating pieces. Each step comes from a piece's own declaration and ends in that piece's event. A script refuses anything else.

## 2. What is decided (owner, 2026-11-22)

1. Each floating skill declares its steps in a `flow-step.json`. `flow-candidates.sh` lists them, and `flow-agree.sh` refuses any step that is not declared.
2. Every step ends in an event, never in a criterion. The human's judgement is a recorded gate, and its answer is already an event.
3. Discovery has no step of its own. "Build the context" is the step, it ends in `context.cut`, and discovery is how that step is done.
4. Each entry declares `stage`, a list of at least one name. Only the scan reads it: no script checks the order of stages, and core's prose gives no sequence. Core owns only `prepare`. A domain declares its own stage names, for example build, test and review.
5. The flow skill tells main to run the scan. The effort skill names nothing, and no hook runs it.
6. "Beside" is settled now: one rule, one helper, used by every scan.
7. At prepare, the flow is offered and the human can say no. It is enforced only at dispatch, with no way round it, and that belongs to the dispatch build. Flow changes need the human's recorded yes once dispatch enforces flows; that also belongs to the dispatch build.

## 3. `flow-step.json`

A component that offers steps has one `flow-step.json` next to its `SKILL.md`. The file is a JSON array of entries:

```json
[{ "name": "build-context",
   "do": "Build the context the work needs, and cut it on the human's yes",
   "uses": "crucible-discovery, crucible-context",
   "done_when": { "event": "context.cut" },
   "stage": ["prepare"],
   "fits": "before work starts, whenever the work needs outside material" }]
```

| Field | Rule | Read by |
|---|---|---|
| `name` | Lowercase letters, digits and `-`; unique within its file. With the component folder it forms the step's key, `<component>/<name>`. | `flow-agree.sh` and `flow-change.sh` (they match a key), the scan's output |
| `do` | One line | the card, the track, main |
| `uses` | One line naming the skills involved; a hint, nothing resolves it | main, the card |
| `done_when` | `{event: "<type>", match?: {<body field>: <value>}}`, exactly the event form used today. Its event type must have exactly one rule file. | `flow-step-done.sh` (copied into the flow) |
| `stage` | A list of one or more names, each of the same form as `name` | `flow-candidates.sh --stage` only |
| `fits` | One line saying when the step is worth proposing | main |

There is no order, no `optional`, no `flows` and no criterion.

The first three files cover the prepare stage:

| Component | `name` | `done_when` | `stage` |
|---|---|---|---|
| `crucible-context` | `build-context` | `context.cut` | `prepare` |
| `crucible-grill` | `grill` | `grill.ended` | `prepare` |
| `crucible-spec` | `specify` | `spec.approved` | `prepare` |

Domain steps (identity, worktree, build, test, review) come with their pieces. None is written here.

## 4. "Beside": one rule, one helper

**The rule:** a component's neighbours are the other folders in the folder that holds it, as the script was called. The path is read as text, and no link is resolved.
- Installed, a script is called through its skill link (`~/.claude/skills/<component>/scripts/...`), so its neighbours are every linked component, core and domain alike.
- Called by its real path (the evidence runs), its neighbours are core's own folder.

**The helper:** `crucible-events/scripts/lib/beside.sh`, holding one function, `bs_components <script path>`. It prints the folder that holds the caller's component, from the path as text.

It has three users:
1. `event-write.sh`'s rule lookup, which today uses `cd -P` (real folders);
2. `effort-close.sh`'s open-work scan, which today reads the path as called;
3. the new catalogue scan.

**Hooks run through the links too.** Today `install-entries.sh` prints every hook command by its real path in the source tree, while main runs scripts through the skill links. Under this rule, a hook would see only core and a script would see every component, so "beside" would have two answers in one install. That works today only because the one hook that writes an event writes a core event. So `install-entries.sh` prints every hook command through its component's skill link as well, and `install-check.sh` checks it.

**The install:** today only folders holding a `SKILL.md` are linked, so `crucible-events` is not, and `event-write.sh` needs `cd -P` to find it. From now on `install-entries.sh` links every component folder, which is every folder directly under a `main-thread/` folder, `crucible-events` included. `install-check.sh` checks the new link. A folder with no `SKILL.md` in the skills folder should not count as a skill to Claude Code. A script run can't show how Claude Code treats one at session start, so the Validator runs one preflight in the sandbox before this is relied on: start a session with `crucible-events` linked, look for a warning, and confirm the skill list is unchanged.

## 5. The scan: `flow-candidates.sh`

```
sh flow-candidates.sh [--stage NAME]
sh flow-candidates.sh --stages
```

- **Where it looks:** every `<neighbour>/flow-step.json` that `bs_components` finds.
- **What it prints:** one line per valid entry, sorted by key:
  `<key> · <do> · ends with <event>[ <match>] · stages: <names> · fits: <fits>`
- **`--stage NAME`:** prints only the entries whose `stage` holds NAME.
- **`--stages`:** prints each stage name it finds, with its number of entries, so a misspelt stage shows as a stage with one entry.
- **A file or entry that is invalid:** wrong shape, a duplicate name, or an event with no rule or more than one. It is left out and named on stderr, one line per problem. The scan still exits 0, so one broken file never blocks a flow. A step that isn't listed simply can't be agreed.
- **Exit:** 0 for printed (an empty result included), 2 for a usage error. It reads only.

The listing and the checks live in `crucible-dynamic-flow/scripts/lib/catalogue.sh`, shared by the scan, `flow-card.sh`, `flow-agree.sh` and `flow-change.sh`.

## 6. The flow and its scripts

The flow file main writes now names steps, never describes them:

```json
{ "goal": "<one line>",
  "steps": [ { "id": 1, "step": "crucible-context/build-context" },
             { "id": 2, "step": "crucible-grill/grill" },
             { "id": 3, "step": "crucible-spec/specify" } ] }
```

| Script | Change |
|---|---|
| `flow-card.sh` | Resolves each key through the catalogue and prints `do`, `uses` and the ending event per step. An unknown key is refused, named. |
| `flow-agree.sh` | Refuses an unknown key. A key whose file or entry the scan rejected is refused with the scan's reason, not just "unknown". It copies each entry's `do`, `uses` and `done_when` into `flow.agreed`, so later replays don't depend on the catalogue. The gate is unchanged: `flow-agree` on the flow file's sha256. |
| `flow.agreed.jq` | A step is `{id, step, do, uses, done_when}`, with an event `done_when` only. There is no flow-level `done_when`. |
| `flow-change.sh` | `add` takes `{"add": {"id": N, "step": "<key>"}, "before"?: ID}`, resolved and copied like `flow-agree.sh`. `skip`, `move` and `reopen` are unchanged. `revise` is removed. The recorded yes for changes waits for dispatch (decision 7). |
| `flow-step-done.sh` | Event steps only: `--event SEQ`, or the one waiting event. `--evidence` and the criterion kind are removed. |
| `flow.step.done.jq` | The body is `{flow, step, event}`. The `kind` field is gone. |
| `flow-end.sh` | `done` needs every step done or skipped, and nothing else. `dropped` still needs the human's words. `--event` and `--evidence` are removed. |
| `flow-replay.jq`, `flow-show.sh` | The marks `[m]` and `[h]` are gone. What is left: `[x]`, `[-]`, `[ ]`, `[!]`. |
| `remind-flow-position.sh`, `open-work.sh` | Unchanged. |

A flow has no `done_when` of its own. It is done when every step is done or skipped.

**A step ends in its own piece's event, never in a raw `gate.answered`.** A later "no" cancels an earlier "yes", and only the gate's own reader knows which answer counts. So the flow never reads gate answers itself; the compliance audit already removed that from `flow.agreed.jq`. The human's judgement becomes a step only through a piece that asks at its gate and writes its own fact, as `spec-approve.sh` writes `spec.approved`. `flow-candidates.sh` refuses an entry whose `done_when` is `gate.answered`.

**The same step may appear more than once in one flow,** for example a second context cut or a spec revision, each with its own id. One event proves one step, so each occurrence needs its own event.

## 7. Prose

- **`crucible-dynamic-flow/SKILL.md`**, rewritten:
  - The description claims the moment: "Use when an effort's work is about to start, when the pre-work is done and the next work is chosen, when the human changes the plan, or when a flow reminder names a step."
  - The body:
    - before work starts, run `flow-candidates.sh --stage prepare` and propose a flow from what it lists;
    - once the pre-work is done, run `--stages` and then the stage the next work belongs to. If no stage fits the next work, go on without a flow;
    - steps come only from the scan; suggest an order, and the human agrees it at the gate and may say no;
    - "a step is an outcome the human would ask about" is removed, and so is the JSON example's free-text steps;
    - the example becomes the three keys above.
  - No stage name besides `prepare` appears.
- **`crucible-discovery/SKILL.md`**, description: gives up "at the start of an effort's work"; it keeps "how main finds out what the work is about".
- **`crucible-context`, `crucible-grill`, `crucible-spec`:** no prose change. Each gains a `flow-step.json`.
- **Known mentions:** `crucible-context/flow-step.json` names `crucible-discovery` in `uses`, a hint for the reader. It and the flow example's keys are the only places one piece names another, and neither is a pattern to copy.

Until dispatch brings build steps, `--stages` lists only `prepare`. A build that main writes itself therefore has no flow. That follows from the decisions, and HANDOFF says so.

## 8. Specs

- `specs/crucible-dynamic-flow.md`: the catalogue, the flow file and the script changes.
- `specs/crucible-events.md`: `beside.sh`, the rule change in `event-write.sh`, and the install linking every component.

## 9. Evidence

Each run starts from `/`, takes every path from stdout and hides nothing.

1. **The catalogue:**
   - the three prepare entries are listed;
   - `--stage prepare` lists them;
   - `--stage build` lists nothing;
   - `--stages` prints `prepare 3`;
   - a scratch component with a bad file (wrong shape, duplicate name, an event with no rule, a `done_when` of `gate.answered`) is named on stderr, shown in the run's output, and left out, and the scan exits 0.
2. **Agreeing:**
   - an unknown key is refused;
   - a free-text step (`do` with no `step`) is refused;
   - a criterion is refused;
   - a key from a rejected file is refused with the scan's reason;
   - the same key twice, under two ids, is agreed, and each occurrence is marked by its own event;
   - a good flow is agreed, and the event holds the copied entries.
3. **Changing:**
   - `add` with an unknown key is refused, and with a catalogue key it is accepted;
   - `revise` is refused as an unknown op.
4. **Marking:**
   - `--evidence` is refused;
   - an event step is marked by its event;
   - `flow-end.sh --outcome done` is refused while a step is open, and accepted once every step is done or skipped.
5. **Beside, installed:** through skill links in a scratch skills folder that also holds a stand-in domain component with its own `flow-step.json`:
   - the scan lists the domain entry;
   - `event-write.sh` finds a rule through its link without `cd -P`;
   - `effort-close.sh` sees the domain's `open-work.sh`;
   - a hook, called through its link, writes an event whose rule sits in another component.

   Called by real path, core's runs are unchanged.
6. **Install:**
   - every hook command `install-entries.sh` prints goes through a skill link;
   - `install-entries.sh` prints a link for `crucible-events`;
   - `install-check.sh` reports it missing until it is linked.
7. **Every other evidence run:** rerun, with output unchanged apart from ids, hashes and times, and the dynamic-flow run rewritten for the new flow shape.

## 10. Not in this design

- Enforcing a flow at dispatch, matching the send to an open step by its event, and the recorded yes for changes: the dispatch build.
- One step against several sends (parallel agents, fix rounds): the dispatch build.
- Domain `flow-step.json` files: these come with their pieces.
- A Stop-hook reminder to offer a flow: only if a live run shows main not offering one.
- Old flow events written in sandboxes: no migration, since no real effort holds one.

## 11. Fable's review (2026-11-22)

Sound, with fixes A–D, now written in:
- A: hooks run through the skill links;
- B: no raw `gate.answered` step;
- C: no stage fits the next work, so main goes on without a flow;
- D: a live preflight for a component folder with no `SKILL.md`.

Also written in: a rejected key is refused with the scan's reason, and the same step may appear twice in one flow.

## 12. Beta's questions to Fable

1. Does the design keep a flow from carrying anything but declared steps, through every path: agree, change and mark?
2. Is the key `<component>/<name>` with the entry copied into `flow.agreed` right, or should the flow keep only the keys?
3. Is it sound to drop the flow's own `done_when`?
4. `beside.sh` in `crucible-events` and linking every component: is that the right home and the right install change?
5. Should the scan leave invalid files out with an exit 0, or refuse?
