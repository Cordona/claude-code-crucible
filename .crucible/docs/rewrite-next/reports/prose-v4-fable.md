# Agent prose v4, a shared report skill and the reviewer reordered: Fable's check (2026-11-25)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** the brief, `agent-report.md` and the three definitions in `prose-v2/`, the live `agent-conduct`, and `report-check.sh` for the forms of a location.

**Not done:** I ran nothing.

## Verdict

**The reviewer's new order and "MR/PR" are good as they are. The shared skill is right for two of its three parts, and one line in it fails its own test.**

| # | Finding | Weight |
|---|---|---|
| 1 | "What an earlier report said isn't said again" is false for a reworked plan | fix before applying |
| 2 | `noticed` is not plumbing: each agent's own check holds it | the owner's call |
| 3 | The skill says "your tree", and the reviewer has none | wording |
| 4 | The builder's and the tester's field lists no longer mention `noticed` | wording |
| 5 | The `@<where>` example doesn't match the check | wording |

## 1. Does `agent-report` pass its own test?

**Two parts pass.**
- **One JSON object at the report path:** true for every report.
- **The forms of a location:** true for every `at`, and no definition explained them before. This is the plumbing's own contract, since `report-check.sh` checks it for every agent. Sharing it is sharing plumbing, which is the owner's rule.

**One line fails.** "It covers this task only. What an earlier report said isn't said again" is true for the reports and false for a plan. The tester's own line says the opposite: "A rework is the whole plan again." A tester reworking a plan holds both. Move the line back to where it is true:
- the builder's report;
- the tester's report on written tests;
- the reviewer's report, where half of it already sits on line 26.

## 2. Shared and specific

**`noticed` is the open question, and it is the owner's.**
- **For the skill:** every report takes it, with the same three fields, and the conduct skill already tells every agent to report an instruction or a secret. The skill gives that rule its place.
- **Against:** it is not plumbing. The builder, the tester and the reviewer each check `noticed` in their own rules, and the reviewer's has one field more. So the prose would have one home and the checks three. When one agent changes its `noticed`, the shared text is wrong for it. That is the coupling the owner ruled out on 2026-11-24.
- **What I'd do:** keep the skill to the plumbing's contract (the object and the locations) and leave `noticed` in each definition, as three copies. If the owner wants it shared, the honest form is to move its check into the plumbing too, so the text and the check share a home.

**Where the skill lives.** Its text and `report-check.sh` must change together. I'd keep it with the plumbing (`agent-submission`), as that component's words to the agent, not as a component of its own.

**Smaller:**
1. **"In your tree."** The builder and the tester work in a tree. The reviewer changes nothing and is told of no tree. Write "in the code" or "in the tree you were given", and "relative to its root".
2. **The field lists.** With `noticed` moved out, "When there is something to say" in the builder and the tester reads as the full list, and it lacks `noticed`. A report with an unknown key is refused, so an agent wants the whole list in one place. The reviewer's draft does it right: it names `noticed` in each section and explains it nowhere. Do the same in the other two.
3. **The reviewer, line 60:** "`noticed`: what you saw outside your lens" defines the field a second time, differently from the skill's "outside your task". Keep one.
4. **`@<where>`.** The skill says "such as an installed dependency (`@vendor:...`)". The check's own words are "another repo's, not looked up". A dependency under `vendor/` is usually a plain path inside the tree. Use another repository as the example.
5. **`-path:N`** is refused in a task that has nothing to compare against. The refusal says so in one line, so I'd leave the skill silent on it.

## 3. The reviewer's order

**It reads naturally.** The four tasks follow the life of a change, and the opening, the description and the sections agree.

- **"A finding" between the challenge and the review** is the right place: just before its first use, and after the one task that has none.
- **"MR/PR":** fine, and consistent through the file.
- **One thing the order makes visible:** the Work list is written for reviewing a change ("Review the change"), and the first task is now a plan. It was so before, and each line still holds for a plan. No edit.
