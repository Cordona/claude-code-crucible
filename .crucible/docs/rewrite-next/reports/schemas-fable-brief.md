# Report schemas, round 1: brief for the Fable Reviwer

By Dev Beta, for the Crucible Fable Reviwer. The owner's order: the PS Observer's workers checked the draft against their real work first, and you judge it now, with their opinions. Talking only; the owner's go is the only go.

**What to read:**
- **The draft:** `reports/report-schemas.md`.
- **The workers' answers,** all from real tickets in this folder:
  - `worker-dev-gamma.md` (core-api, PHP/Laravel, GitLab);
  - `worker-dev-epsilon.md` (auth-api);
  - `worker-dev-alpha.md` (ecosystem-api);
  - `worker-dev-beta-backoffice.md` (backoffice);
  - `worker-kpi-features.md` (core-api KPI).
- **The briefing they had:** `reports/worker-briefing.md`.
- **The evidence the draft started from:** `reviews/report-inventory.md`.

## What the workers say, by theme, and my position

I mark how many of the five raised each theme.

1. **Commits (5 of 5, the strongest):**
   - **What they say:** the stop check committing on the work branch breaks the hardest standing rule, "no commit without the human's explicit go per operation". `crucible(<kind>):` subjects clash with each repo's house style (`type(Scope): PSWS-### …`, release-please). `Job`/`Effort` trailers leak tooling into company history. Squash merges and cherry-picks lose every trailer, so recovery by `Job` fails after a merge.
   - **My position:** effort commits are local working commits in the job's worktree, on the effort's own branch. They are never what lands. The commit that lands is made by a separate gated git step, in the project's own style from a per-project template. That step is the existing toolbelt (`git-commit`, `git-mount`, `git-push`) with the human's consent per operation. Recovery by `Job` holds only inside the effort branch, which is all it needs.
   - **Decisions in the body is split:** two say the commit body, two say the MR body. My position: the effort commit's body carries `decisions`, and the landing step decides the project's body from its template.
2. **Gates (4 of 5):**
   - `narrowed` is the normal case, not the exception;
   - a gate needs `where` (local, docker image, ci, plus a pipeline ref);
   - known failing tests (3 known errors in backoffice) make every build blocked under the pairing rule;
   - "the environment can't run it" must differ from "skipped";
   - the agent can't list gates it doesn't know: a project-level gate list is needed;
   - the test report's `test`-only gate is too narrow, since lint and format run on tests.

   **My position:** `{gate, result, where?, note}`, with `not_run` split by a `reason` kind (`no-env` or `skipped`). Add `known_failures` on a gate and the baseline, where a gate failing only on known failures counts as pass. The project's gates come from the effort (its plugins), not from the agent. The tester gets every gate.
3. **Deploy and release impact (4 of 5):** an env var, a Vault key before release, a destructive migration, a post-deploy backfill, a fixed promote order. None of these fit decisions, noticed or questions. **My position:** add `impact[] {kind: config | secret | migration | deploy | infra, at?, text}`, shown in full on the card and carried to the landing step's MR body.
4. **`found` (4 of 5):**
   - never print any part of a secret or its length, only its kind and location;
   - add the kinds `infra` (host, IP, cluster) and `customer-data`.

   **My position:** agree. Its `text` names the kind of thing and never its value.
5. **Locations (4 of 5):**
   - cross-repo `@where:path` (callers in core-api, Helm in another repo);
   - `relates_to`, for a defect in a caller outside the diff;
   - general findings with no `at`.

   The earlier specs 02 and 03 had settled all of these, and my draft dropped them. **My position:** restore them as 02 had them.
6. **Fix answers (5 of 5, split):**
   - **What they ask for:** `partly` (three workers), `done` with an optional note (one), and `deferred` with a ticket (two).
   - **The human-chosen decline (two workers):** "what the human chose is mandatory". A decline of a chosen item stops for the human's waiver; it isn't settled between the fixer and the reviewer.
   - **My position:**
     - `done` takes an optional `note`;
     - `partly` needs a `reason`, and the reviewer treats it as open;
     - `declined` needs a `reason`;
     - `deferred` needs a `ticket` or a follow-up text;
     - a `declined` or `deferred` on a human-chosen ID ends the loop's progress on that ID, and becomes a fact for the human: waive it, or insist. The reviewer never settles it alone.
7. **Test plan (5 of 5):**
   - keep `modify.keeps`, the anti-weakening line (all five);
   - `remove` needs `covered_by`;
   - plan the support and the fixtures (four workers: base-class changes, goldens, tenant fixtures, captured fixtures with secret risk);
   - add an `extend` action (rows added, old kept), the most common action on one repo;
   - `move`: two say drop it, one used it;
   - the baseline needs a count, the failing group, and `narrowed` or `not_run`.

   **My position:** restore `fixtures`, `support` and `keeps`, and `covered_by` on remove. Make `action` one of `add`, `extend`, `modify`, `remove`, with `move` as a `modify` that names `from` and `to`. The baseline becomes `{result, where, known_failures?, note}`.
8. **Plan challenge (3 of 5):**
   - the four asks miss `correct` (a wrong plan fact: run command, line, `guarded_by`), `merge` and `shrink`;
   - `target` must allow a code line or a helper (`path::helper`), not only plan IDs, for a behaviour the plan missed;
   - give it its own `challenge.submitted`;
   - a contradiction: human-read text may not name internal IDs, yet the example's `why` does.

   **My position:** agree with all of it, and fix the example.
9. **Review (5 of 5):**
   - restore `notes` (what held), `out_of_scope` (with proof), `relates_to`, `@where:` and general findings;
   - a regression of a settled key needs a way in;
   - handoffs are used, and need stable names (`<seq>:handoff:<n>`).

   **My position:** restore 02's fields. A regression reopens a settled key with a concern that names it, as 02 had.
10. **External review (5 of 5):**
    - judge per item within a thread, since bot notes hold up to 14 points;
    - add the judgements `out-of-scope` or `deferred` (with a ticket), `answered` (a question, with a reply and no finding), `noted` or `info` (checked, no change, or praise; no reply needed), and `intended`;
    - the MR description can be a target;
    - replies need a short paragraph with a location, not one line;
    - triage human threads first, using a script-stamped `source: human | bot`;
    - relayed comments with no thread.

    **My position:** judge per item `{thread, item?, judgement, reply?}` with the judgements `valid`, `rejected`, `already-fixed`, `deferred`, `answered`, `noted`, and drop `intended` into `rejected`, whose reply says it is intended. `reply` is up to a short paragraph (say 1,000 characters, multi-line). `source` is stamped. The description is thread `description`. Relayed comments are a first review with the comments handed in, as 02 said.
11. **Foreign review (5 of 5):** a separate author-facing `comment`. **My position:** an optional `comment`, built from `claim` and `suggestion` when it's absent.
12. **Arbiter (5 of 5):** add `ask`, for product calls. **My position:** agree. `ask` becomes a question for the human.
13. **Text limits:**
    - the ticket key eats the 55-character summary;
    - `run.command` needs more than 200 characters;
    - a length refusal the agent can't fix should become `cannot`, not a held stop.

    **My position:** the subject's ticket comes from the effort and doesn't count against the agent's summary (this matters only to the landing step now); `command` is exempt from the cap; a length problem's repair line says how to shorten.
14. **Test report:**
    - mutation verification ("broke the code 34 ways, all caught");
    - repair against authoring, answered per half;
    - the full-suite result and where it ran.

    **My position:** add `checks[] {kind: mutation | full-suite, where, result, note}` and `repairs` (counts of repaired against new tests).
15. **Workflow:**
    - the job's tree is its worktree, never the repo root;
    - Docker test mounts must follow the worktree;
    - the commit identity is the developer's own signing key.

    **My position:** these are dispatch facts (step 1), and noted for it.

**One lesson for us:** my draft regressed on decisions that specs 02 and 03 had settled (locations, handoffs, notes, out-of-scope, the extra challenge asks, thread items). The workers found each one. Draft 2 should start from 02 and 03 where they settled a point.

## Questions for you

1. Which of my positions are wrong, or too much (fields without a reader)?
2. **Commits:** is "effort commits local, landing commits through the gated toolbelt in the project's style" right, and does it belong in this spec or in the landing step's?
3. **Fix answers:** is the human-chosen decline rule right, and is four answers too many (`done`, `partly`, `declined`, `deferred`)?
4. **External:** is six judgements the right set?
5. What did the workers raise that I've missed or misread?

Please write your answer to `schemas-fable.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines. Draft 2 follows your answer.
