---
name: standard-spec
description: What a spec is, the human-approved contract for an effort's work (its what and why in five sections, never the how), which every dispatch has, as small as the work. Bind when drafting or revising one with the human; an agent reads one by its context rules. Writes nothing itself. Not for running the drafting and the approval (`procedure-context`), the handover (`standard-artifact-handoff`) or a `flow-harness-authoring` run's `spec.md`.
user-invocable: false
---

# Standard: Spec

A spec is the contract between the human and the agents for one effort's work: the what and the why, approved by the human at its approval gate. It fits any kind of work: code, documentation, design, architecture.

## Scope

- **Inside an effort only,** as part of building its context. Work outside an effort has none.
- **Not here, and none loaded by this skill:**
  - drafting the spec, its approval gate and its place in the context: `procedure-context`, which loads this skill;
  - handing the spec over: `standard-artifact-handoff`;
  - a skill's or agent's `spec.md` in a `flow-harness-authoring` run: its sections differ.

## Never

- **Never put the how in a spec:** no files, parts, structure or step list that build the result (in code, its functions and types; in a document, its outline). The agent that builds owns the how.
- **Never put a tool or technology choice in a spec** unless the human requires it; then it goes in Constraints.
- **Never put the project's own rules in a spec** (its tools, style, commands): its plugins and standards hold them, and a copy drifts.
- **Never revise a spec during an effort for a small change** (a rename, a reword, a small fix).

## Always

- **Every effort gets a spec, as small as its work:** a one-line fix gets a few lines under the same five headings. There is no skip; the only offer is a revision's.
- **During an effort, revise the spec only when a change alters the work's goal, done-when or scope:** a new draft, through its approval gate.
- **The human has the final say:** they approve each draft at its gate, or reject it.
- **Every agent dispatched after it works from it.**
- **Every agent still running gets a revised spec's path** in its next change and every later one, as the spec that replaces the earlier one.

## The five sections

Each is a `## ` heading, in this order:

1. **Goal:** what and why: the problem, and who it is for.
2. **Done when:** what is true when it is finished, as behaviour or results the human can check.
3. **Scope:** what is in, and what is out (the no-gos).
4. **Constraints:** what must hold or must not be touched, and what needs the human's OK first.
5. **Open points:** unknowns and risks. At approval none is open, or the human leaves every point still listed to the developer: each becomes the developer's call.

## Form

- **Free-form Markdown with the five headings,** each version written once to a `--label spec` effort draft, allocated as `crucible` sets for drafts. A revision is a new draft; the newest is the current one.

## Self-check before the approval ask

Check each draft before it goes to its gate; one that fails is fixed in a new draft.

1. The five sections are `## ` headings, in order.
2. No how (Never).
3. No tool or technology choice, unless the human requires it, then in Constraints.
4. None of the project's own rules.
5. Each Done-when item is something the human can check.
6. Its size fits the work.
