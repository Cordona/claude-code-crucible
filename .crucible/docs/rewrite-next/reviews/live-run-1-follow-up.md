# Acting on live run 1: the discussion so far (2026-11-21 and 22)

Hand-over from Crucible Fable Reviwer to Crucible Dev Beta. The owner and I talked through how to act on the first live run. The owner moves that discussion to Beta's session from here; whatever is decided there, I verify. Nothing below is decided or authorized: it is the state of the thinking.

The run's report: `.crucible/docs/harness/runs/decisions/new-rewrite-replay/report.md`. My judgment of it is in the message I sent Beta on 2026-11-21 ("Judgment of the first live run").

## The owner's concern

Main did not offer to negotiate a dynamic flow for building the context. The owner ranks this as the biggest issue of the run, because it will bite harder in the complex flows (build, test, review), where an unagreed plan means main alone decides how many agents, which reviews and when to stop.

## Why it happened (my reading of the evidence)

1. **The discovery skill claims that moment.** Its description says "use at the start of an effort's work". Right after the effort opened, main said "Next comes discovery" and went there. I reviewed that description and passed it; that was my miss.
2. **The flow skill's trigger is vague.** "When a goal needs several steps." Main did not see "build the context" as a goal to plan, but as the obvious next thing.
3. **Nothing in code notices.** The flow's Stop hook speaks only about flows that exist. An effort with no flow at all is invisible to it.

So the small skills formed a fixed sequence by themselves (effort, discovery, spec), which is what the rewrite set out to remove.

## The owner's hypothesis: main has no catalogue of step candidates

The owner's words: main is supposed to offer a dynamic flow, but it has no "catalogue" of what could go into one, "pieces that could be added or skipped". For the context, the tools are discovery, grill and spec. How could main know these can be nodes?

My answer: partly right. Main does see every skill with its one-line description, and in the run it knew the steps (its effort card listed them). So the missing offer came from the trigger, not from missing knowledge. But three things really are missing, and they would weaken any flow main proposes:

1. Nothing marks which pieces are flow-sized. Discovery, grill and spec are steps; gate and events are not.
2. Main doesn't know how each step proves it is done (`grill.ended`, `spec.approved`). In the one flow it proposed, every step was a criterion main verifies; none was a checked event.
3. Nothing puts the optional steps in front of main or the human. No grill was offered in the run.

## The idea, as it stood when the discussion moved

**Step candidates, declared by each component.** A component that does flow-sized work ships one small entry: what the step achieves, which skill does it, what proves it done, and one line on when it fits. A short script in the flow component scans for these and prints them. A candidate carries no order. It is the same pattern as each component declaring its own hooks and its own open work, and it is the catalogue the owner asked about, built by a script so it can't go stale.

The owner's reaction: there is merit in it; it is "still a catalogue, but a programmatic one"; and how does main know to run the script?

**The owner's own idea for the trigger:** tie it to something concrete the framework can see, not to main detecting intent. Dispatching a build agent means a flow should be negotiated; the same for a test or a review agent. A hook could call the candidates script. "The script is invoked automatically somehow, based on the event bodies logged?"

**Where I took that:** yes, and one step earlier, since at dispatch the plan is already made.

- **One rule, read from the events: an open effort with no open flow means a flow must be negotiated.** The flow's Stop hook already reads the effort's events at each stop. When that state holds, it runs the candidates script and tells main, once: this effort has no agreed flow; here are the candidates; propose the steps.
- That one rule fires at each moment that matters, knowing nothing of build, test or review: when an effort has just opened; when the context flow has ended and the spec is approved; when a build flow has ended.
- **The owner's dispatch idea becomes the backstop.** When dispatch is built, it refuses to send an agent unless an open flow covers that work, and its refusal prints the same candidates. A reminder can be ignored; that refusal can't.
- **The agreement card shows what was left out.** Under the chosen steps, the candidates not in this flow ("Not in this flow: grill"). The human then sees what could be added or skipped at the moment they decide, whatever main chose.
- **The two descriptions are corrected.** Discovery stops claiming the start of an effort; the flow skill claims it.

## The owner's limits on any solution

- **No complex machinery.** "I would gently push back on complex machineries."
- **It must scale to the truly complex flows:** build, test, review.
- **A line in `CLAUDE.md` or a reference file is acceptable** ("if you detect the human builds something, run this"). My view: it would work as a fallback, but it is the weaker choice on this run's evidence: prose triggers are what failed, while main followed every hook line it was given, nine of nine.

## What it would cost, as sketched

- One small entry file per flow-sized component (today: discovery, grill, spec).
- One short script that lists them.
- A few lines in the existing flow hook, and in the agreement card.
- No new hook and no engine.

## Open for the owner

1. Is "an open effort with no open flow" the right single rule, or should the trigger sit elsewhere?
2. A reminder now with a refusal only at dispatch, or a refusal already for context work? I recommended the reminder: a refusal now would make every component know about flows, and there is no evidence yet that main ignores the reminder.
3. What a candidate entry holds, and whether "when it fits" belongs in it.
4. Whether the agreement card should list the candidates left out.
5. A second live run that reaches what the first did not (a flow agreed for the context, steps marked, a change mid-way, a grill). I suggested driving it from a task brief, not from another conversation's prompts.

## Also open from the run, not yet discussed with the owner

- Two of sixteen context entries were never read before the spec was approved. I recommended counting it again, not building for it.
- Main filled in the spec's two open points itself before asking for approval, and said so.
- Twelve outcome-changing questions were asked in plain sentences over three turns.
- The sandbox's replay session is still open at a dialog.

## Design questions I would check when a design comes to me

- Does the hook's new rule stay a fact read from events, with no knowledge of what kind of work is going on?
- Does a candidate entry stay order-free, so no fixed pipeline comes back through the catalogue?
- Does `uses` stay informational, or does something start to resolve it? If the dispatch refusal checks that a flow "covers" the work, something must match a step to a piece; that is a real change to the node and needs its own decision.
- Does the cost stay inside "no complex machinery" once build, test and review each add entries?
