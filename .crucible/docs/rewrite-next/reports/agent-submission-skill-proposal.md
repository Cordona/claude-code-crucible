# The shared report skill: what it holds, and what leaves the agents

By Dev Beta, at the owner's request: "Draft a proposal, align with Fable and if he approves, explain what the skill will contain and what will be scrubbed from the agents."

It's built as Fable's v4 verdict set, and the owner approved both of Fable's calls (no `noticed` in the skill; its home is `agent-submission`):
- skill: `new-rewrite/domains/software-development/core/agents/agent-submission/SKILL.md`;
- definitions: `code-builder.md`, `code-tester.md`, `code-reviewer.md` beside it.

## The test

A line goes in the skill only when both hold:
1. it's true for every report kind of every agent;
2. what checks it is the shared plumbing (`agent-submission`'s `report-check.sh`), not an agent's own rules. That's why it lives in `agent-submission`: the text and the check change together.

## What the skill holds

| Line | Checked by |
|---|---|
| Write one JSON object to the report path | the stop hook: no object, no submission |
| It covers this task only | none; true of every kind |
| What an `at` can be: `path`, `path:N`, `path:N-M`, `-path:N` (a deleted line, at the base), `@<where>:path[:N]` (another repository), or a list | `report-check.sh`, before any agent rule |
| A path is relative to the tree's root; a line must exist | `report-check.sh` |

## What leaves the agents

| Agent | Removed | Why |
|---|---|---|
| builder | "Write one JSON object to the report path" | the skill says it |
| tester | the same line, at both the plan and the report on written tests | the skill says it |
| reviewer | the same line | the skill says it |

## Considered and kept in the agents

| Rule | Why it stays per agent |
|---|---|
| "What an earlier report said isn't said again" | false for a plan: a rework is the whole plan again |
| `noticed` | three checks (builder, tester, reviewer with `for`); one prose home over three checks is the coupling the owner ruled out |
| `gates` | the reviewer has none, and the builder has no `mutation` |
| `fixes` | same name, different statuses: done/partly/declined against fixed/open/agree/disagree |
| `summary`, `decisions`, `impact`, `questions`, `blockers` | builder and tester only, each with its own blocker kinds |
| findings, plan fields, the plan's ID rule | one agent each |

## New in it

The location forms weren't explained to any agent before, though every agent writes `at` and a bad one is refused. That's the one thing the skill adds that wasn't written anywhere.

## Fable is asked

Does the live result match your v4 verdict, and does anything in the skill or left in the agents fail the test above?
