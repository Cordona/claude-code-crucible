# Dev Alpha, round 3: the six proposals vs real work

Checked against `round-3-proposals.md`, `event-timeline.md` and `report-schemas.md` (draft 2). The evidence is ecosystem-api (PHP/Laravel, GitLab, MRs !10–!19, reviewed by Ivo and a bot). "GUESS" marks an inference. Read only.

## 1. One `noticed`, with `security` and `for`: fits, if the two flags are defined apart

- **Fits:** PSWS-1948's tester would flag a fixture holding a real-looking key with `security: true`. The PSWS-1813 security lens's audit-logging handoff to observability fits `for`.
- **Breaks: the two flags overlap.** The example `a.sh:9 evals user input, for: security` is a security concern without `security: true`, so main wouldn't hear about it first. Define them apart:
  - `security` is the old `found`: something that must not be there;
  - `for` is a possible defect for another lens.
  Or let `for: security` imply the floor.
- **Lost: `kind`.** `secret` and `instruction` need different handling. A planted instruction (a bot comment, a README line) is untrusted text, not a leak. Keep it, e.g. `security: "secret" | "instruction"`.
- **Keep stable names:** a `for` entry still needs its key (`<seq>:handoff:<n>`, or `<seq>:noticed:<n>`). The PSWS-1813 re-check picked one as `handoff:3`.
- **Text never holds the value, or its length.** Same as r1.

## 2. Test-plan event names: fit, with one gap

- **Fits:** submitted, challenged, updated, approved matches PSWS-1813's draft, challenge, rework, then gate.
- **Gap: a human's change at the plan gate has no event.** On PSWS-1813, the human asked for changes at the gate (5 amends rejected for length, test 14 dropped). Is that a `test-plan.updated` with no challenge answers, or a new `submitted`? Name it. "Done when every challenge is answered" must not treat it as a challenge round.
- **Small:** every other human yes is `gate.answered`. Say whether `test-plan.approved` is a second event or replaces it.

## 3. No `files` in `build.submitted`: fits, only while the effort branch is never rebased

- **Better than a list:** the commit shows deletes and renames, which an agent's list can miss.
- **Breaks on a rebase.** On !12, main moved and we rebased with `--force-with-lease`. If an effort branch is ever rebased, every `commit` in the events goes stale, not only the file lists. The spec should say so: the effort branch is never rebased, and main is merged in instead.
- **What the stop check commits decides the list.** Our main checkout carries untracked files (`.crucible/`, deploy templates). The effort's worktree must start clean, or the stop check must refuse paths the job didn't touch. Otherwise the list includes them. GUESS: worktrees make this rare.

## 4. Report path back in every event: agree

There's nothing against it. It's how a reviewer of my build would find my `decisions` and `impact`.

## 5. External review, a finding inside its item: fits most, breaks on one real case

- **Breaks: one item, two findings.** On !14, the bot's F-03 held two claims, compatibility and PHP. We split them into F-03a and F-03b and answered each. A single `finding` can't carry both. Allow `findings: [...]` in an item, or let the agent split the label (`F-03a`) and say the reply groups back to `F-03`.
- **Still open from r1:**
  - A `valid` item also needs a reply once fixed. My !10 replies named the fixing commit per item. In timeline 4, the replies gate (6–8) seems to come before the fix loop ends. Say which reply a `valid` item gets, and when.
  - Relayed comments with no thread (Ivo's !16 points came through chat) still have no `thread`.

## 6. `answers` keeps its name: agree

The fixer's values (done, partly, declined) and the reviewer's (fixed, open, agree, disagree) don't overlap, so one name is unambiguous.

## Timeline, one note

Flow 2 answers my r1 point: a decline goes to the human on the end card, and "send it back" makes it not declinable. That matches our rule that what the human chose is mandatory.
