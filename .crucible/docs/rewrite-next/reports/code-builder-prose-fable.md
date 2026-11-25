# The builder's prose: Fable's check (2026-11-24)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** the draft `code-builder.md` (38 lines), the old one (62 lines, as evidence), `build-agent.md` and the constitution.

## Verdict

**It is lean, it stands alone, and the cuts are right.** Every cut removes something a script now does or something that no longer exists. Growing from this smallest version is the right way.

**Four lines are missing,** each for a slip nothing else catches, and one sentence should go. That is still under 45 lines.

## 1. What I'd add

| # | The slip | Why nothing catches it | The line |
|---|---|---|---|
| 1 | Customer or tenant data, or query output, in report text | already decided: no script can check it, so each agent's prose carries it as one line. The draft covers secrets only | beside the secrets rule: report text never holds customer or tenant data or query output |
| 2 | A change outside the tree, such as in the human's own checkout | the commit takes the tree only, so the stray change stays where it is, unseen | "Change nothing outside your tree." |
| 3 | A run on part of the suite reported as `pass` | the stop check can't know what was run | on `gates`: a run on part of the checks is `narrowed`, with what ran |
| 4 | Fixing what it noticed outside the task | "fix only what was asked" is a standing rule in the workers' projects, and the draft only implies it | on `noticed`: what you saw outside the task and left as it is |

**One more, about the report's shape.** The draft names the keys but not what an entry holds. A builder must guess that a decision is `at`, `choice`, `why`, or that a gate has `gate` and `result`.
- The stop check will correct it, but a job ends at the second refusal. So a builder that guesses spends its one repair on the shape.
- Give each key its entry in a few words, in the bullets that are already there: `gates`: each `{gate, result}`; `decisions`: `{at, choice, why}`; `noticed`: `{at, text}`. No new lines, no example block.
- If the owner prefers to learn it first: make "accepted at the first stop" the first thing the live run counts.

## 2. What I'd cut or change

- **Line 9's list of what the prompt names** (the job, its kind, the tree, the task, the known failures, the report path). It describes the dispatch's prompt, which isn't designed. A piece that restates another piece rots when that one changes (section 15). Keep "Your prompt gives you the job" and let the prompt speak for itself.
- **"Tests belong to the tester" gives no reason.** Section 6 asks every rule to name the failure it prevents. Six words do it: the author would be grading its own code.
- **"Never commit"** should cover the rest in the same line: no git command that writes. A stash or a reset in the tree is as silent as a commit.

## 3. The cuts, checked

| Cut | Right? |
|---|---|
| The report skills | **Yes.** The stop check owns the rules, and the prose names the keys |
| Seats, re-seats, change messages, the merge | **Yes.** None of it exists now |
| The `git restore` and `rm` rules | **Yes.** No hook sends the builder there |
| The step-by-step process | **Yes.** Five guidelines, in no forced order |
| The three-attempts cap on a red check | **Yes for now.** A builder that keeps trying costs time and isn't silent. Add it back if a live run shows a loop |
| The model, the plugins, `omitClaudeMd` | **Yes.** The dispatch decides them |

## 4. To know, not to change

**Nothing checks that a builder left the tests alone.** The tester's scope is checked by a script; the builder's is this one line, and the reviewer sees the commit. That is a fair place to start. If a live run shows a builder editing a test to make it pass, that is the case for a rule in code, not for more prose.
