# Agent prose v4: a shared report skill, and the reviewer reordered

By Dev Beta, at the owner's request. The drafts are in `prose-v2/`: `agent-report.md` (new), `code-builder.md`, `code-tester.md`, `code-reviewer.md`. The live copies (v3, as you approved it) are under `new-rewrite/domains/software-development/core/agents/`.

## 1. `agent-report`: what every report shares

The owner asked for one skill holding the report rules all agents share, without misleading an agent into fields its reports don't have. The test I used: a line goes in only if it's true for every report kind of every agent. Three things pass:
- **The envelope:** one JSON object at the report path; this task only; an earlier report isn't repeated unless it still stops this task.
- **What an `at` can be:** `path`, `path:N`, `path:N-M`, `-path:N`, `@<where>:...`, or a list. These are `report-check.sh`'s forms. No definition explained them before, though every agent writes `at`.
- **`noticed`:** every kind now accepts it, with the same `{at, text, kind}`.

Each agent's own definition keeps everything else:
- `gates` (the reviewer has none);
- `fixes` (same name, different statuses: the clearest case of sharing that would mislead);
- `summary`, `decisions`, `impact`, `questions`, `blockers`;
- findings, plan fields and the plan ID rule.

The reviewer adds `for` on `noticed` in its own text, and the tester keeps its line on generated keys.

It's loaded from frontmatter, next to `agent-conduct`, and is its own component, so the installer links it by itself. The definitions don't name it (§15).

## 2. The reviewer

- **"MR" became "MR/PR"**, since we use both GitLab and GitHub.
- **Reordered for the reader**, following the life of our own change and then outside work:
  1. challenge a test plan;
  2. a finding (the shape the next three use; a challenge has none);
  3. review a change, including re-review;
  4. judge an outside review of our MR/PR;
  5. review someone else's MR/PR.

  The opening and the description list the tasks in the same order.

## What Fable is asked

1. Does `agent-report` pass its own test: no line an agent could take as a field its report lacks?
2. Is anything shared still repeated in a definition, or anything specific wrongly moved into the skill?
3. Does the reviewer's order read naturally to the agent?
