# The agent definitions and the plugins against the new mechanics: Fable's fit review (2026-11-24)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read, line by line:** the three agent definitions, all 17 `SKILL.md` bodies, and all 33 role files (`build.md`, `review.md`).

**Not done:** I ran nothing. I checked no report key against the built rules; the earlier check by Dev Beta stands for that. The know-how notes in section 5 are what I noticed in passing, not an audit.

## Verdict

**They fit.** In about 2,700 lines I found no seat, no relay, no report format, no finding ID, no agent told to do another agent's work, and no reviewer told to edit. The words that touch the report (`gate format`, "record it", "a gate step doesn't run") all land on something the stop check has.

**One question of mechanics is open and matters,** and it is the owner's: what `pass` means on a check that was already red. Everything else is small and mechanical: 23 edits in 19 files.

## 1. For the owner

### 1.1 What `pass` means on a check that was red before

**The plugins say one thing and the mechanics another.**
- **Every language's gate** says: take a baseline of each warning and finding before the change, run again after, and compare. PHP's says it outright: the format check "passes when the change adds no unformatted file to the baseline".
- **The stop check** knows only this: a `fail` whose failures aren't in the job's known failures needs a `gate_red` blocker. Known failures come from the job, never from the agent.
- **The definitions** say "only what turns red because of you is yours to fix", and nothing about how to report a check that was red before and is no redder.

**Why it matters.** A real project has old lint findings. A builder that adds none will report either `pass`, which hides that the check is red, or `fail`, which blocks the job on something nobody asked it to fix. A job can list a few known failing tests; it can't list two hundred lint findings.

**What I'd do:** say it once in the builder's and the tester's definition, since four languages depend on it.
- For `format`, `lint` and `typecheck`: `pass` means no redder than before you started. When it wasn't clean before, add a `note` with the counts before and after.
- For `test`: unchanged. A failing test is `fail`, and the job's known failures excuse it.

### 1.2 Two lists that repeat their own plugin

`accessibility/references/build.md` and `clean-code/references/build.md` each end with a "Build so that" list. It is a short restatement of that plugin's own `SKILL.md`, which the builder receives with it. The other six standards have no such list. I'd delete both; it is the owner's call, because the brief said not to trim.

### 1.3 The version ledgers go stale

Each tech plugin ends with a ledger of defaults (PHP 8.4, Laravel 12, Spring Boot 3, React 19, a named latest `rustc`, a named Node). They apply only when the project states no version, which is rare. They are dated facts in prose, and nothing updates them. Two I can speak to are in section 5. I'd leave the ledgers and give them an owner later; no edit now.

## 2. The agent definitions

| File | Line | Edit |
|---|---|---|
| `code-builder.md` | 28 | add: `not_run` needs a `note` saying why. The tester's file says it; the builder's doesn't, and the stop check refuses without it |
| `code-builder.md` | after 28 | add the line from 1.1, if the owner agrees |
| `code-tester.md` | 35 | "`support`: the shared files the tests need" becomes "`support`: every other file the tests need or you will change (a fixture, a helper, a factory, a suite list, a folder of goldens)". The scope check allows only what the plan names, so a tester that reads "shared files" will leave out the factory and be refused in the test job |
| `code-tester.md` | after 56 | add the line from 1.1, if the owner agrees |
| `code-reviewer.md` | none | fits as it is |

## 3. The standards

| File | Line | Edit |
|---|---|---|
| `performance/references/review.md` | top | add: "Store access is in scope for building. In this review, grade only the cost outside a durable store." The body says store access is in, in full; the severity list grades only non-store cases. A reviewer holding both has a store N+1 that is in scope and has no level |
| `accessibility/references/build.md` | 10–17 | delete "Build so that" (1.2) |
| `clean-code/references/build.md` | 7–15 | delete "Build so that" (1.2) |
| `self-documenting-code/references/build.md` | last | add the missing final line break |
| the other standards | none | fit as they are |

**Checked and found consistent when an agent holds several at once:**
- security says to fetch secrets from a secret manager, and Laravel reads settings from the environment: security's own scope line (follow the project's secret handling) settles it;
- performance and persistence both speak of N+1, unbounded reads and offset paging, and say the same thing;
- self-documenting-code and each language's Docs line agree: a doc comment only where the signature can't say it;
- testing's "the human waives it" matches the plan's `recommend` and the plan gate.

## 4. The tech plugins

**One edit in all nine `SKILL.md` files.** The Toolchain list has a step: "What the project's own docs … say, where the task's context lists them." "The task's context" was the old context file. It becomes: "where your prompt names them".

| File | Line |
|---|---|
| `languages/php/SKILL.md` | 27 |
| `languages/kotlin/SKILL.md` | 25 |
| `languages/shell/SKILL.md` | 23 |
| `languages/rust/SKILL.md` | 24 |
| `languages/typescript/SKILL.md` | 31 |
| `frameworks/laravel/SKILL.md` | 21 |
| `frameworks/nextjs/SKILL.md` | 22 |
| `frameworks/react/SKILL.md` | 24 |
| `frameworks/spring/SKILL.md` | 24 |

**The rest:**

| File | Line | Edit |
|---|---|---|
| `languages/typescript/SKILL.md` | 91 | move "Name each finding by its rule id …" to `typescript/references/build.md`, after the baseline paragraph. The other four languages have it there. In the body it also reaches the reviewer, who runs no gate |
| `frameworks/nextjs/SKILL.md` | 50 | "is a finding" becomes "is a defect". The body is read by the builder too, and the languages say "defect" |
| `frameworks/react/SKILL.md` | 98 | the same |
| `frameworks/spring/SKILL.md` | 74 | the ledger row "`ScrollPosition` and `Window` available from: unknown" becomes "Spring Data 3.1 (Spring Boot 3.1)". A row that says "unknown" sends the builder to guess |

**Checked and found consistent:**
- a framework held with its language: Laravel's "Eloquent, every value bound" over PHP's "PDO prepared statements", and Next.js's `next/dynamic` over React's `React.lazy`. Each framework says it comes after its language, and each says what it replaces;
- every gate step names one of the eight gates, and "a build is not a per-change gate" matches a builder that simply doesn't list `build`;
- "a new dependency goes into the build file only; its download is left to the human" fits an `impact` or a question, and the step that needs it is `not_run` with its reason;
- the severity words are capitals in the plugins and lower case in the report; no agent needs help with that.

## 5. Know-how, noticed in passing

1. **TypeScript's Zod rules are written for Zod 3,** and the ledger's default is 3.x. As far as I know, Zod 4 replaced `.passthrough()` and `.strict()` with `z.looseObject()` and `z.strictObject()`. A project on Zod 4 would get rules that name methods it shouldn't use. Worth checking against Zod's current docs before a real run; the Toolchain should also read the project's Zod version, as it reads the others.
2. **Spring's default is Boot 3,** and Boot 4 has been out for about a year. It only applies when a project states no version.
3. **The testing standard's review file** grades "a test not in the approved plan" and "a planned test not exercising its planned break". That needs the review job to carry the plan. It is one more field for the dispatch: a review of tests names its plan.

## 6. What I looked for and didn't find

| Hunted | Found |
|---|---|
| A seat, a relay, a first message's sections | none; one old phrase in nine files (section 4) |
| A report format, field or ID the stop check lacks | none |
| A gate name outside the eight | none |
| An agent told to write another agent's code or tests | none |
| A reviewer told to edit | none |
| A contradiction with an agent definition | one question (1.1) |
| A contradiction between plugins held together | one, inside the performance plugin (section 3) |
| Step trees and babysitting | none worth an edit. The Toolchain lists and the gate steps are ordered because the order is the know-how |
| Words a script already enforces | none in the plugins. The definitions name report keys on purpose, while a job ends at the second refused report |
