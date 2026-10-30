---
name: standard-spec
description: What a spec is, the human-approved contract for an effort's work (its what and why in five sections, never the how), and when an effort needs one. Bind when judging whether work needs a spec or drafting one with the human; an agent reads one by its context rules. Writes nothing itself. Not for running the drafting and the context entry (`procedure-context`), the handover (`standard-artifact-handoff`) or a `flow-harness-authoring` run's `spec.md`.
user-invocable: false
---

# Standard: Spec

A spec is the contract between the human and the agents for one effort's work: the what and the why, approved by the human in their own words. The main thread drafts it with the human through `procedure-context`, which also enters it in the context. It fits any kind of work: code, documentation, design, architecture.

## Scope

- **Inside an effort only,** as part of building its context: a spec is discipline, not paperwork. Work outside an effort has none.
- **Work that builds nothing needs no spec, and that is no skip** (a grill about the human's understanding of an existing system, say), judged on the work now asked for. Every rule below is for work that builds something.
- **Not here, and none loaded by this skill:**
  - drafting, skipping and entering the spec in the context: `procedure-context`, which loads this skill;
  - handing the spec over: `standard-artifact-handoff`;
  - when a dispatch may be offered: `procedure-context`'s "what next?" and each flow's dispatch check;
  - a skill's or agent's `spec.md` in a `flow-harness-authoring` run: its sections differ.

## Never

- **Never put the how in a spec:** no files, parts, structure or step list that build the result (in code, its functions and types; in a document, its outline). The agent that builds owns the how.
- **Never put a tool or technology choice in a spec** unless the human requires it; then it goes in Constraints.
- **Never put the project's own rules in a spec** (its tools, style, commands): its plugins and standards hold them, and a copy drifts.
- **Never skip a spec at an effort's start without the human's word.**
- **Never offer a new or revised spec during an effort for a small change** (a rename, a reword, a small fix).

## Always

- **Every effort gets a spec unless its work is too small.** The main thread judges "too small" with care; when a spec looks like overkill, it says so and offers to skip it.
- **A skip, or the human's "no spec" at any point while drafting, ends the drafting** and is recorded as a context note, `Spec skipped: "<the human's words>"`, so a skipped spec is told apart from a missing one.
- **During an effort, offer a new or revised spec only when a change alters the work's goal, done-when or scope,** whether its spec was approved or skipped.
- **The human has the final say:** they can ask for a spec, or reject one offered.
- **The human approves the spec in their own words,** a plain "yes" included, before anyone builds to it.
- **The approved spec is the `paths` entry whose path is a `--label spec` draft, its why `the approved spec`, with a note `Spec approved: "<the human's words>"`.** Every agent dispatched after it works from it; every agent still running gets a revised spec's path, as the spec that replaces the earlier one, in its next change and every later one.
- **An agent learns how to read a spec from its context rules,** not from this skill: it builds to the what, and owns the how.

## The five sections

Each is a `## ` heading, in this order:

1. **Goal:** what and why: the problem, and who it is for.
2. **Done when:** what is true when it is finished, as behaviour or results the human can check.
3. **Scope:** what is in, and what is out (the no-gos).
4. **Constraints:** what must hold or must not be touched, and what needs the human's OK first.
5. **Open points:** unknowns and risks. At approval none is open, or each is marked as accepted.

## Size and form

- **Size fits the work:** a small spec is a few lines.
- **Free-form Markdown with the five headings,** each version written once to a `--label spec` effort draft, allocated as `crucible` sets for drafts (not loaded here: `procedure-context` allocates it). A revision is a new draft; the newest is the current one.
