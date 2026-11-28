# The split probe: initialize the agent, then give it the job. Fable's review of the design (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `spikes/dispatch/split-design.md`.

**Not done:** nothing was run; this is a review of a probe's design. I have not checked how Claude Code delivers a start hook's context or whether it limits its size. Section 2 asks the probe to find out.

## Verdict

**The concepts are right, and this is better than my brief by path.** Plugins belong to the agent and the job belongs to the call. The owner's doubt about a brief the agent must choose to read was fair, and this design removes the choice where it matters.

**Confirmed to run, with five additions to the probe.** None changes the design. Without the first two, a green result would not show that the plugins arrived and were used.

## 1. Why the split is right

- **A hot agent can't change its plugins.** So they were never part of the job. The log said so only by accident; now it says it by shape.
- **Nothing is rewritten,** so auto mode reviews exactly what runs.
- **Hot and cold carry the same job text,** by one door.

## 2. Additions to the probe

1. **Use the largest real plugin set.** The swapped briefs were 10 to 22 KB, most of it plugins. If Claude Code cuts a hook's context at some size, a small set passes and the real one doesn't. The byte-equal check in question 1 then has to be on the largest set a builder gets today.
2. **Show the plugins were used, not only delivered.** Six of six accepted at the first stop measures the report's shape. An agent with no plugins at all could pass it. One cell needs an outcome that differs when the plugin was not read, as the planted facts did in the final verification.
3. **Force the start hook to fail once.** A start hook probably can't stop the agent. So an agent whose setup failed would run with no plugins and hand in work that looks fine. That is the silent failure this framework exists to remove. Record what happens today. The spec will need a mechanical answer, and the likely place is the hand-in: a cold agent's first job with no `agent.initialized` is not accepted.
4. **Count what auto mode says about main's own calls.** This is the point of the redesign: for every cold start and the hot message, zero "no verdict" and zero denied.
5. **Measure the job message, and check it is sent as printed.** Main retypes it, so it stays short only if the spec, the context and the grills go in as paths. Record its size in bytes for each of the six jobs, and how many calls the checking step refused because main's text differed from the door's.

## 3. Two points for question 2

- **One source for the setup.** The tree hook is the only step that holds both the note and the agent's id. The start hook should read the setup from the event log by agent id, not from the notes folder. The probe records which step wrote `agent.initialized` and from what.
- **The door takes plugin names only for a cold start.** For a hot job it takes none. The probe needn't build the refusal, but the results should say what the door did.

## 4. For the record, not for this probe

- **`agent.initialized` and the smaller `job.dispatched` are JSON shapes.** The owner approves them before anything is built.
- **A hot job keeps the agent's tree.** A hot job on another tree is not possible, and the spec should say what the door does when asked.
- **The spec, context and grills are still files the agent chooses to read.** That was always so. The owner's "no choice" now holds for the plugins and the job text, which are the two that matter.
