# Acting on live run 1: the proposals for review (2026-11-22)

The owner and Beta continued the discussion from `live-run-1-follow-up.md`. This file holds every proposal made since: the owner's, Beta's, and where the two differ. Nothing is decided or authorized. Fable: please review all of it, including the owner's proposals Beta argued against.

## The two problems, as the owner frames them

1. **Drama 1, missing gates.** Main asked about twelve outcome-changing decisions in plain sentences, across three turns, with no card and no options. The report's raw:276, raw:720 and raw:867.
2. **Drama 2, the missing flow.** Main never offered to negotiate a flow for building the context. Discovery, grill and spec float as separate pieces, and main has no way to know they are candidate steps of one flow.

## Gate events

- **Owner:** emit events only for gates that are critical milestones, such as an agent dispatch, and perhaps starting a spec or a grill. The facts are the grill when finalised and the spec when approved, not their drafts.
- **Beta:** this is how it works today. Only a recorded gate writes `gate.answered`, and a gate is recorded only when a script acts on the answer: spec approval and flow agreement, with dispatch to come. Drafts are files, not events. The events are `grill.ended`, written once when the grill is finalised, and `spec.approved`. Starting a grill or a spec needs no gate event. Nothing to change.

## Drama 1: missing gates

- **Owner:** this can't be enforced by a script. Fix it with targeted, well-defined prose.
- **Beta:** agreed; no script can tell that a plain sentence was a decision. One sentence in discovery, where it happened. Something like: "A question whose answer changes what is built is a gate: batch up to four in one question dialog behind one small card." Batching keeps the turns the same as the plain sentences.

## Drama 2: the missing flow

### Where discovery, grill and spec live

- **Owner's proposal A: move them under `crucible-context/`.** That would carry the idea that they are parts of the context.
- **Owner's question:** can discovery, grill and spec be used outside the context and outside an effort? The owner thinks yes. The alternative is that wanting a discovery, a spec or a grill makes main offer an effort, so their events have a home.
- **Beta: don't move them; declare instead.**
  - The grill serves more than the context, for example a design question during review, or an unclear bug. Nesting it fixes one grouping in the tree.
  - Discovery writes nothing, so it can run without an effort. Grill and spec write files and events, so they need one. That supports the owner's alternative: wanting a grill or a spec means main offers an effort first.
  - The install would still link nested skills, since it finds every SKILL.md, but the move buys only the signal, and a declaration carries it without fixing the grouping.

### How main knows the candidates

- **Owner's proposal B: the context skill as the wrapper.** The context skill, or a reference beside it, says the context is a dynamic flow with these candidates. If the pieces sit under the context folder, a shared script collects every skill under that root and generates the candidates JSON. Main offers them with no fixed order, suggests an order, and negotiates. Nothing is added by hand.
- **Beta: the same idea, with a declaration instead of a folder.** Each skill that can be a flow step ships one `step.json` beside its SKILL.md:

```json
{ "achieves": "Turn an open goal into recorded decisions",
  "uses": "crucible-grill",
  "done_when": { "event": "grill.ended" },
  "flows": ["context"],
  "optional": true,
  "fits": "when the goal is still open, or the human asks to be grilled" }
```

  - Discovery: `done_when` is the human's confirmation, `optional: false`, `fits: "always, first"`.
  - Spec: `done_when` is `spec.approved`, `optional: false`, `fits: "always, before agents are sent"`.
  - `flows` is an array, so one step can serve several kinds of flow. The grill could later also be listed under "design".
  - `optional` is the owner's addition. Its readers are main (it must propose the required steps) and the agreement card.
  - `flows` is the owner's renaming of Beta's "goals". It avoids a clash with the flow JSON's own `goal` field, the one-line sentence of what a flow achieves.
  - One shared script in crucible-dynamic-flow, `flow-candidates.sh [--flow KIND]`, collects every `step.json` and groups them by the kinds they name. `--flow` only filters. No order.
  - The context skill says in one line that the context is built as a negotiated flow.
  - Build, test and review later add their own `step.json`; no list is kept by hand.

### The trigger

- **Owner's earlier idea** (from `live-run-1-follow-up.md`): tie it to something the framework can see, such as dispatching a build agent, and a hook runs the candidates script.
- **Beta (and Fable's earlier suggestion): one rule read from the events.**
  - An open effort with no open flow makes the existing flow Stop hook speak once each time that state starts: right after the effort opens, and again after a flow ends.
  - The hook runs `flow-candidates.sh` with no filter and puts every group in its message, for example: "This effort has no agreed flow. Propose one at a gate before going on. Candidates: context: Discovery (required), Spec (required), Grill (optional: …)".
  - The hook never knows the kind of work; main picks the group that fits where the effort stands.
  - It nudges, it doesn't block: the human can still answer "no flow needed".
  - The reason it's a hook and not prose: prose triggers are what failed in the run, while main followed 9 of 9 hook lines.
- **The owner's understanding, confirmed by Beta:** any effort starts with building the context, so main would be nudged at once to offer a flow and negotiate it.
- **The owner's dispatch idea stays as the backstop:** when dispatch is built, it refuses without an open flow, and prints the candidates.

### The agreement card

- **Beta:** under the chosen steps, a line for the optional candidates left out, such as "Not in this flow: Grill (when…)". It could also flag a required one that's missing: "Required, not in this flow: Spec".

### Descriptions

- **Beta (and Fable earlier):** discovery's description stops claiming "the start of an effort's work", and the flow skill's description claims the start of an effort.

## Not yet discussed with the owner

- Whether dispatch's refusal must match a flow step to the work it sends, which would turn `uses` from informational into resolved. Beta: decide it with dispatch.
- The other run findings: 2 of 16 entries unread; main filling in the spec's open points; the second live run.

## What Beta asks Fable to judge

1. Proposal A (moving the folders) against the declaration in `step.json`: which fits the constitution better, and is either complex machinery?
2. The owner's question: do discovery, grill and spec run outside an effort, or does wanting one mean offering an effort first?
3. The `step.json` fields, `optional` and `flows` included. Does each field have a reader? Is anything missing or extra?
4. The trigger: the hook running the script with no filter and listing every group, versus anything simpler.
5. The Drama 1 sentence, and where it belongs.
6. The card lines, and the description changes.
