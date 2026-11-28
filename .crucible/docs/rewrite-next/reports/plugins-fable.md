# The plugins in new-rewrite: Fable's check (2026-11-24)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** the brief, both agents' reports, all 33 role files (`build.md`, `review.md`) in full, the testing standard's `SKILL.md` in full, and the three agent definitions.

**Not done:** I didn't read the other 16 `SKILL.md` bodies line by line. I searched all of them for old machinery and for words that name another piece, and found none. I didn't judge whether the know-how is correct; that was not asked, and the owner has it planned for later.

## Verdict

**The alignment is clean and the plugins fit the three agents.** No plugin names another file, a seat, a flow or a report field. What they ask the agent to "record" maps onto the reports without naming a key, which is the right distance.

**Two real conflicts to fix now, and four answers the dispatch needs.**

| # | Finding | When |
|---|---|---|
| 1 | The reviewer's definition tells it not to judge comments or names, and two lenses judge exactly those | now |
| 2 | clean-code's review file contradicts itself | now |
| 3 | The builder's and tester's definitions never list the gate names | now |
| 4 | Two mutation rules were lost with the old machinery | now, two lines |
| 5 | What a tester receives | the dispatch |
| 6 | A language is a lens too | the dispatch |

## 1. To fix now

1. **The reviewer's definition against two lenses.** `code-reviewer.md` says: "judge the code it runs, not its comments or names". The self-documenting-code lens judges comments and names, and clean-code judges names. The line means "don't take a comment's word for what the code does". Say that: take what the code does from the code, not from what its comments or names claim.
2. **clean-code's review file** lists "tight coupling that blocks change or testing" as a finding, and then says "it blocks testing" never raises one. Take "or testing" out of the first line. It is two words, and a reviewer will meet the contradiction on its first job.
3. **The gate names.** The definitions say each gate is `{gate, result}` and never say what `gate` may be. The stop check takes eight names and refuses any other. Today a builder learns four of them only from its language plugin, and a job with no such plugin would guess.
   - Put the list in the builder's and the tester's definitions: one line each.
   - Keep the names in the plugins' gate steps. Which of a language's steps is which gate (PHP's syntax check is the type check) is that language's know-how.
4. **The mutation rules.** The tester must report the `mutation` gate on every test job, and the standard no longer says how to do it well. Two of the three lost rules are know-how, not machinery:
   - break the behaviour a test guards, never an implementation detail;
   - where the project has its own mutation tool, run that.

   Put them in the testing standard's first section. The third (a bug fix's test fails on the code before the fix) is already there.

## 2. The five open points

| # | Point | My view |
|---|---|---|
| 1 | A role file points at sections of its own `SKILL.md` | **Acceptable.** A plugin is one piece: its body and one role file. Make it a rule of the dispatch that a role file never travels without its body, and say so where plugins are described |
| 2 | The tester has no plugin reference | **It needs two things, and both exist already.** Section 3 below |
| 3 | Testing's `test.md` was dropped | **Right.** It was the old report machinery. Restore the two rules of finding 4; no new role file for two lines |
| 4 | Self-documenting-code's duplication check needs a path the job may never carry | **Leave it.** The rule says itself that a missing path is no evidence, so it sleeps and harms nothing. Change its word "brief" to "your prompt". Whether a review job carries the MR's description is the dispatch's |
| 5 | clean-code's contradiction | **Fix it,** finding 2 |

## 3. What a tester receives

**The testing standard's body.** It is almost all know-how for writing tests, and the owner already decided that a tester's setup always includes the testing standard. So the tester gets `SKILL.md`, with no role file.

**The language's verification gate.** The tester runs the builder's gates, lint and format on test files included, and those steps live in each language's `build.md`. So for now the tester also gets its language's `build.md`. What else is in that file (a new dependency is left to the human, no project-wide change) holds for a tester too.

**No `test.md` for the nine tech plugins yet.** What the agents list (PHPUnit against Pest, `runTest`, Testing Library) is knowledge the model has, and the testing standard already says to map each concept to the project's own framework. The one thing the workers really needed was a filtered run, and that is a project's rule. Write a `test.md` when an integration run shows a tester stumbling on something a file would have told it.

**One correction to my own advice:** I asked for a line in the tester's definition about masking a captured fixture. The testing standard already has it, in its section on golden fixtures. If the tester always gets that standard, the line has one home there and shouldn't be added to the definition.

## 4. A language is a lens too

The brief says a reviewer's lens is a standard plugin. The files say more: every language and framework has a `review.md` with a Correctness section, and the workers' real findings are numbered `PHP-01` and `KOTLIN-01`. So the correctness review is the language's own lens.

Nothing in the plugins needs to change. The dispatch needs to know it: a review through a standard's lens gets that standard's review file, and a correctness review gets the language's.

## 5. Smaller

- **"Injected into the agent's job by the dispatch"** is in every standard's description. It describes a dispatch that isn't designed, in eight places. It can go; the description isn't used to pick the plugin.
- **"CRITICAL: none for this lens"** reads like an empty line, but it is a rule: this lens never grades that high. Keep it.
- **The severity words** are in capitals in the plugins and lower case in the report. An agent maps them without help.
- **self-documenting-code's `build.md`** has no line break at its end.

## 6. The owner's plan: no live runs now

**Right for the plugins.** They can't be judged apart from the logic that picks them and hands them to an agent. One thing to look at when that runs: how much a job carries. A builder with one language, one framework and three standards gets about 650 lines before its task.
