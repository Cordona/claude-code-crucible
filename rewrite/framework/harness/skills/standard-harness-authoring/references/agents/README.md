# Agent checklists (agent-01–08)

Agent checklists for agent files (`agents/**/*.md`), one perspective each, so each reviewer seat judges one file.

## Files

- `01-agent-need-and-role.md` (AROLE): whether the agent should exist, its one job, its opening, stance and scope.
- `02-agent-frontmatter-and-tools.md` (ATOOL): valid frontmatter, least-privilege tools and their enforcement, model, effort and turns.
- `03-agent-context-and-load.md` (ALOAD): what the agent knows at startup, what it loads, and what that costs.
- `04-agent-dispatch-contract.md` (ADISP): how it gets picked (description) and what it accepts (Your dispatch, fail closed).
- `05-agent-judgment-quality.md` (AJUDG): evidence, honesty, verifier stance and independence, process steps.
- `06-agent-output-contract.md` (AOUT): the return shape its caller parses, completeness, and coverage.
- `07-agent-safety.md` (ASAFE): the canonical blocks, write boundaries, and side effects outside scope.
- `08-agent-testing.md` (ATEST): the runs that must happen before use, shown by the run outputs and grades.

## Terms

- **Dispatch-only agent:** only a flow or script dispatches it; the main session never picks it by its description.
- **Selected agent:** a flow dispatches one of several agents by a key (the stack, the lens). It's described like a dispatch-only agent, naming its flows and the key.
- **Routed agent:** the main session picks it by its description.
- **Orchestrator-only agent:** runs only as the main session (`claude --agent <name>`); never dispatched as a subagent.
- **The agent's text:** its body plus the skills it preloads. An item about the body passes when either carries the rule.
- **Verifier:** any agent that judges another agent's output, including a code reviewer judging a developer's change.
- **Waivers file:** the target's waivers file, as `SKILL.md` Invariants define it.
- **Dispatching flow:** a `flow-*` skill, or any skill section or agent that holds the steps dispatching this agent. Find them by grepping the agent's name.

## Which checklists apply

| Agent kind | Apply |
|---|---|
| Reviewer / verifier (judges another agent's output) | agent-01–08 in full |
| Writer / implementer (writes files) | agent-01–04, agent-06–08; agent-05 except AJUDG-09–AJUDG-14 |
| Analyst (reads and reports, no verdict) | agent-01–04, agent-06–08; agent-05 except AJUDG-09–AJUDG-13 |
| Orchestrator-only | agent-01; agent-02 except ATOOL-19–ATOOL-21; agent-03 except ALOAD-01; ADISP-10 only; AJUDG-16–AJUDG-18; agent-07; ATEST-01–ATEST-04 |

Each file's "Applies when" line narrows further; an item that does not apply is N/A with the reason.

## Seating and ownership

- Seat `agent-reviewer` per applicable agent checklist, or in the combined seats `flow-harness-authoring`'s Reviewer swarm names for a small agent; a combined seat judges each of its agent checklists' lists in turn. The agent-03 seat also judges 02 (lean writing), STR-05, STR-06 and STR-09 (section order, against the Agent file row of the rulebook's "Reading order by kind"); the agent-07 seat also judges SAFE-01 (with the preloads as context), SAFE-03 and SAFE-07; the agent-02 seat also judges checklist 10 when the agent declares `hooks:`. Borrowed items keep their own MUST or SHOULD level.
- One problem fails once. Tool grants and how they are enforced: agent-02. What the body says about where it writes and what it never touches: agent-07. Whether a claim is backed: agent-05. Whether the reply can be parsed: agent-06. The brief, the seat choice and how the caller treats the reply: 06.
- A pattern about the dispatching flow (brief templates, escalation, vote merging, fencing data in briefs) is judged in 06 or 04, never here.
- Writing, reviewing and testing an agent file with `agent-author`, `agent-reviewer` and `eval-grader` is `flow-harness-authoring`'s Agent flow.
