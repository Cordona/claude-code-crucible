# Dev Alpha: report schemas vs real work

Reviewed against `report-schemas.md` (draft 1, 2026-11-24).

**My evidence:** ecosystem-api, a PHP 8.4 / Laravel service on a GitLab project. Its work: the Editors API epic (PSWS-1313, 1726, 1727, 1733, 1813, 1948, 1834), Helm values, and MRs !10–!19, reviewed by a human (Ivo) and by an AI bot.

**Read only:** I changed nothing in the spec.

**Marking:** "GUESS" marks an inference; everything else happened.

## 1. Does each report say what real work needs?

**Build:**
- **Missing, deploy impact.** PSWS-1834 added an env var to the UAT and PROD Helm values. Merging it restarts pods on UAT and PROD, needs a Vault key to exist first, and had to wait for a lunch-break window. A related ticket ran in a fixed order: promote first, then migrations. `noticed`, `decisions` and `questions` can't carry this. The MR body and the human need it before the merge.
  - Suggest an `impact[]` field (`{kind: deploy|migration|config|secret, text}`) that the card shows in full.
- **`found` masking:** `AKIA****` still leaks a prefix and the length. Our standing rule is "never print a secret value or its length". Use kind and location only, never a fragment.
- **`gates`:** the gate list fits our stack: `test` (phpunit), `typecheck` (phpstan), `format`, `scan`, `lint` (`helm template`), and `manual` for a live check. But "every gate the project has is listed" needs a project-level gate list. The agent can't know what it didn't run.
- **Never used:** nothing. `decisions` replaces our "deferred to the commit message" rationale. Good.

**Fix:** see 2.

**Test plan:** see 3. Also:
- **Keep `modify.keeps`.** It is the guard against repaired-assertion drift. When the uuid change broke 45 tests on PSWS-1313, "what this test still asserts" was the one fact a reviewer needed per repair.
- **`move`:** never used. Drop it.
- **A contradiction:** "Human-read texts never name an internal ID", but the challenge example's `why` says "T-1 passes with any limit above two", and the card shows it.

**Plan challenge:**
- **Four asks lose two real kinds.** The PSWS-1813 challenge had about 9 plan-field fixes (a wrong run command, wrong line numbers, a wrong `guarded_by`), and row shrinks. Neither fits `add`, `change`, `remove` or `prove`.
  - Add `correct` (a plan fact) and `shrink`, as the 03 spec had.
- **Lost check:** the 03 spec's rule that an `add` must end with at least one new test.
- **Event:** give a challenge its own `challenge.submitted`. It is not a code review.

**Code review:**
- **Missing, `relates_to`.** "Every finding's `at` is in the job's cover" refuses a real defect in a caller. PSWS-1813's PHP-013 was exactly that, and legacy checked it against the hunks. The 02 spec already has it.
- **Missing, `@where:` locations** for another repo. Our callers live in core-api.
- **Missing, `out_of_scope`.** A defect that is valid but the same on main.
- **Missing, `notes`.** "What held", per thread, too.
- **Missing, regressions of settled keys.** `answers` covers only the IDs the job names.

**Text length:** 200 characters is fine for claims. It is too short for a reply posted to a human reviewer (see 5).

## 2. Fix: is `done` / `declined` enough? Is `partly` needed?

- **`partly`:** I'd add it, with a required `reason`, answered by the reviewer like `done`. A fixer that knows it covered one of two places should say so. "Done" that the re-review then reopens costs a round. Legacy's rule: a partly addressed finding stays open.
- **A bigger gap:** "an ID the human chose cannot be declined without a reason" goes against our rule "what the human chose is mandatory". In legacy, a decline of a chosen item stopped for the human's explicit waiver. Sending it only to the reviewer lets a fixer and a reviewer agree to skip what the human asked for.

## 3. Test plan: plan fixtures before tests, or report them?

- **Report them** (the tester's report), with one exception: a fixture captured from a live system. For PSWS-1948 (Bugsnag redaction), fixtures held secret-shaped keys. Where a captured fixture comes from, and that it holds no real secret, must be approved before it's captured, not after.
  - Suggest an optional `captured[]` in the plan (`{file, from}`), and nothing else.
- **Support files:** report-only is fine for us. GUESS: the base-class case (Dev Beta's) may differ.

## 4. Review: are the realism classes workable? Is `handoffs` used?

- **Realism:** workable. `proof` on edge-cases and `real_if` on hypotheticals are what the human and the PSWS-1813 background re-check used.
- **Realism ranks, it doesn't gate.** An edge-case HIGH (PSWS-1813 PHP-011, a restore/destroy race) wasn't picked. It came back from the AI review on !14 as F-05, judged REAL/HIGH, and was fixed.
- **`handoffs`:** used. The 1813 re-check keyed one as `handoff:3`, and a security lens handed audit logging to observability. They need a stable name (`<seq>:handoff:<n>`, as in 02) to be picked or re-checked.

## 5. External review: do valid / rejected / already-fixed cover real PRs?

No. Five cases they miss:
- **Praise and "checked, no change".** Ivo's note on !16 had 1 finding plus 4 "checked, no change" items, and a bot note can be praise only. That needs a `noted` judgement, or the thread can't be answered.
- **Several findings, and two claims in one item, per thread.** The AI note on !10 had 14 points in one thread. On !14, F-03 held two claims (compatibility and php), which we split. `findings[].thread` handles the 14 points, but `item` (the bot's own label) is needed to reply item by item.
- **Valid but not this change.** The same behaviour on main. That needs `out-of-scope`, a follow-up and no fix.
- **A question to us.** That needs a reply and no finding.
- **Reply length.** A `reply` capped at one line of 200 characters is too short. My replies on !10 were 14 multi-line notes, each citing code. A rejection to a human reviewer needs a short paragraph with a location.

Relayed comments with no thread (Ivo's !16 points came through a chat) don't fit `thread`. Per 02, they are a first review with the comments handed in.

## 6. Foreign review: write a comment for the author, separate from the claim?

- **Lean yes. No real evidence:** I never reviewed someone else's MR.
- **GUESS:** `claim` and `suggestion` are written for our fixer, terse and in our vocabulary. A comment to a colleague needs context and tone. An optional `comment`, defaulting to claim plus suggestion, costs little.

## 7. Commits: do the trailers help? Decisions in the body?

**On our project, these commits must not land as they are:**
- **House style:** our commits are `type(Scope): PSWS-### Desc`, with the Jira URL as the only body line and no AI trailer. Delivery is one commit per ticket, commits mapped 1:1 to tickets. The subject alone exceeds 55 characters: "chore(Helm): PSWS-1834 Add EDITOR_API_KEY_ENCRYPTION_KEY to UAT and PROD".
  - Suggest that `crucible(...)`, `Job`, `Effort`, `Fixes` and `Declines` stay in the effort's own commits, which are squashed into project-style commits by a project template before the MR.
  - Finding IDs mean nothing to the human reviewer.
- **Recovery by the `Job` trailer breaks after a GitLab squash-merge.** The project has squash on by default and fast-forward merge. MR !19 merged as a new unsigned commit (a352322) with a tree identical to ours (6852e26), so every trailer was gone.
- **`decisions` in the body:** no for us. They belong in the MR body, which the reviewer reads, not in the commit.

## 8. Awkward on our stack or workflow

- **Signing:** `signed: false` on the card is right. GitLab-made commits are unsigned anyway (see 7).
- **Locations "exist at the head":** fine for Helm (`.deploy/helm/values.*.yaml`). It breaks for cross-repo and vendor files without `@where:` (see 1).
- **One-line limits:** on PSWS-1813, plan edits were rejected for length 5 times. Any edit a length limit rejects should become a `cannot`, not a held stop the agent can't fix.
