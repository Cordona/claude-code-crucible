# Bringing the plugins into new-rewrite: the brief

By Dev Beta, at the owner's request.

## What a plugin is now

A plugin is prose injected into one agent's job by the dispatch. It holds the know-how of one language, framework or standard. Three agents receive plugins:
- `code-builder` writes production code;
- `code-tester` writes tests;
- `code-reviewer` reviews through one lens, and that lens is a standard plugin.

Each agent's own definition already covers the job, the report, the stop check, the untrusted-content and secrets rules, and never committing. Read the three, so you don't repeat them:
- `new-rewrite/domains/software-development/core/agents/code-builder/code-builder.md`
- `new-rewrite/domains/software-development/core/agents/code-tester/code-tester.md`
- `new-rewrite/domains/software-development/core/agents/code-reviewer/code-reviewer.md`

The report shapes are checked by scripts. A plugin never describes a report, a finding's format or an ID.

## What to do

**Copy each plugin from `rewrite/` into `new-rewrite/`,** in the same layout. Then align the copy. Never edit anything under `rewrite/`: it is the legacy, which stays untouched.
- Tech plugins: `rewrite/domains/software-development/plugins/tech/{languages,frameworks}/<name>/` → `new-rewrite/domains/software-development/plugins/tech/{languages,frameworks}/<name>/`
- Standards: `rewrite/domains/software-development/core/plugins/standards/<name>/` → `new-rewrite/domains/software-development/core/plugins/standards/<name>/`

**The rules, from `.crucible/docs/rewrite-next/constitution.md`** (read it):
1. **A plugin stands alone (§15).** It names no other file, skill, section, flow or procedure: no `standard-*`, no `procedure-*`, no `flow-*`, no `code-*` agent, no `(§N)`. A rule it needs, it says itself, in a line. What another file already owns, it drops.
2. **No old machinery:** seats, re-seat, worktree seats, `flow-code-build`, `procedure-seat-run`, the old report skills (`standard-code-build-report`, `standard-code-test-report`, …), report fields, finding IDs, severity formats. All of it goes.
3. **Thin prose (§6):** every line helps the agent do the work better, or it goes. Keep the real know-how: idioms, pitfalls, toolchains, the verification gate a language sets, and what to look for in a review. These plugins were already trimmed by judged swarms on 2026-11-04, so the content is mostly good. Your job is alignment, not a rewrite of the know-how.
4. **Role references:** `references/build.md` and `references/review.md` stay, one per role. The builder gets `build.md`, and the reviewer of that lens gets `review.md`. The tester has no reference today. Don't invent one: list the plugins where a tester would clearly need something (test framework idioms, how to run a filtered test) as a question for the owner.
5. **Frontmatter:** keep `name`, `description`, `disable-model-invocation`, `user-invocable` and `metadata`. In `description`, drop names of other skills and agents.
6. **No new rules, nothing added for completeness.** Keep each file as small as it can be.

## What to report

Report per plugin:
- what you removed, in one line;
- anything you were unsure about.

Then report overall:
- every reference to another file you couldn't remove without losing a rule, and why;
- the tester question.

Don't commit. Never touch `~/.claude`. Don't search from `/`.
