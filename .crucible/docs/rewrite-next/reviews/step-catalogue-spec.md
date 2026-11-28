# The step catalogue: how it will work

This document describes what the step catalogue will do once it is built. The technical design, with its evidence plan and Fable's review, is `reviews/step-catalogue-design.md`. Nothing here is built yet: it waits for the owner's go.

## In one paragraph

Every floating piece that can be a step in a flow declares that step itself, in a small `flow-step.json` next to its skill. A script lists the declared steps, filtered by stage. Main proposes a flow by choosing from that list and suggesting an order, and the human agrees it at a gate. The scripts accept only declared steps. Each step is marked done only by its own piece's event, so a flow can never carry acceptance criteria, free text, or anything main claims itself.

## The parts

| Part | What it is |
|---|---|
| `<component>/flow-step.json` | The steps a component offers. Each entry has `name`, `do`, `uses`, `done_when` (the piece's event), `stage` (one or more names) and `fits` (when it's worth proposing). |
| Step key | `<component>/<name>`, for example `crucible-grill/grill`: how a flow names a step |
| Stage | A filter label. Core owns only `prepare`; a domain declares its own, for example `build`, `test`, `review`. Never an order. |
| `flow-candidates.sh [--stage NAME] \| --stages` | Lists the declared steps, or the stage names with their counts. Reads only. |
| `flow-card.sh`, `flow-agree.sh` | Show and agree a flow made of keys; any key that isn't declared is refused |
| `flow-change.sh` | `add` takes a key only; `skip`, `move` and `reopen` stay; `revise` is gone |
| `flow-step-done.sh` | Marks a step by its event only |
| `flow-end.sh` | `done` once every step is done or skipped; `dropped` with the human's words |
| `crucible-events/scripts/lib/beside.sh` | The one rule for "my neighbours": the folder holding my component, as I was called. Installed, that is the skills folder, so core and domain steps are both found. |

## The first catalogue

| Key | Does | Ends with | Stage |
|---|---|---|---|
| `crucible-context/build-context` | Build the context the work needs, and cut it on the human's yes. Discovery is how it is done. | `context.cut` | prepare |
| `crucible-grill/grill` | Turn an open goal into recorded decisions | `grill.ended` | prepare |
| `crucible-spec/specify` | Draft the spec and approve it at a gate | `spec.approved` | prepare |

Domain steps come with their pieces, for example identity, worktree, build, test and review in software development. A setup step lists every stage it serves, such as `["build", "test", "review"]`.

## A walk-through

**1. The effort opens.** Main offers it at a gate, and the human agrees. Nothing about flows happens yet.

**2. Before any work, main scans `prepare`.** The flow skill tells it to:

```
$ sh flow-candidates.sh --stage prepare
crucible-context/build-context · Build the context the work needs, and cut it on the human's yes · ends with context.cut · stages: prepare · fits: before work starts, whenever the work needs outside material
crucible-grill/grill · Turn an open goal into recorded decisions · ends with grill.ended · stages: prepare · fits: when the goal is still open, or the human asks to be grilled
crucible-spec/specify · Draft the spec and approve it at a gate · ends with spec.approved · stages: prepare · fits: before an effort's work is built or sent to agents
```

**3. Main proposes a flow** from what fits, suggesting an order:

```json
{ "goal": "Know the work well enough to build it",
  "steps": [ { "id": 1, "step": "crucible-context/build-context" },
             { "id": 2, "step": "crucible-grill/grill" },
             { "id": 3, "step": "crucible-spec/specify" } ] }
```

`flow-card.sh` prints the card, resolving each key into its `do` line and its ending event. Main shows the card and asks at the `flow-agree` gate. The human can agree, change it ("no grill, the goal is clear"), or say no flow. No flow is allowed at this stage.

**4. On the yes, `flow-agree.sh` writes `flow.agreed`.** It holds each step's key and a copy of its `do`, `uses` and `done_when`, so the event reads the same later, whatever happens to the catalogue.

What it refuses:
- a key that isn't declared;
- a step written as free text;
- a criterion;
- a key from a file the scan rejected, giving the scan's reason.

**5. The work happens.** Each piece runs as today with its own gates:
- the context is built and cut on the human's "done?" yes, which writes `context.cut`;
- the grill writes `grill.ended`;
- the spec is approved and writes `spec.approved`.

**6. Steps are marked by their events.** `flow-step-done.sh --step 1` finds the waiting `context.cut` and writes `flow.step.done`. There is no `--evidence`: a step without its event can't be marked. The Stop hook reminds main of the next step, as today.

**7. The plan changes when needed.** If the human hesitates mid-way, main can add the grill: `flow-change.sh` with `{"add": {"id": 4, "step": "crucible-grill/grill"}}`. A key that isn't declared is refused. The same step may appear twice, for example a second cut, each with its own id and its own event.

**8. The flow ends.** `flow-end.sh --outcome done` succeeds once every step is done or skipped. There is no separate check.

**9. After the pre-work, main looks at the stages:**

```
$ sh flow-candidates.sh --stages
prepare 3
```

Main scans the stage the next work belongs to. While only `prepare` exists, no stage fits a build, so main goes on without a flow and writes the code itself under the code rule. Once dispatch and the domain steps exist, `--stages` will also list the domain's stages, for example `build` with its step count, and main proposes a build flow the same way.

## What it guarantees

- **A flow holds only declared steps.** Every path into a flow checks this: agreeing, changing (`add`) and marking.
- **Every step is ended by its own piece's fact,** never by main's word and never by a raw gate answer. The human's judgement becomes a step only through a piece that asks at its gate and writes its own event, as the spec does.
- **No order lives anywhere in the catalogue.** Main suggests one and the human agrees it.
- **Pieces stay apart.** A component offers steps through a file of its own, and adding one changes no existing file. Core names no domain stage.

## What it does not do yet

- **Enforcement at dispatch:** once dispatch exists, the sender refuses to send an agent without an agreed flow holding an open step whose ending event matches what the send will produce.
- **A recorded yes for flow changes:** comes with dispatch.
- **Several sends for one step** (parallel agents, fix rounds): decided with dispatch.
- **A reminder to offer a flow:** added only if a live run shows main not offering one.

## Before it is relied on

What changes in an install: every component folder is linked into the skills folder, `crucible-events` included, and every hook command points through its component's skill link, not into the source tree.

One live preflight by the Validator: once every component folder is linked into the skills folder, `crucible-events` included, check that Claude Code shows no warning and that the skill list is unchanged.
