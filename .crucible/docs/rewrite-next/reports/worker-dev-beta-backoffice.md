# Dev Beta [Backoffice]: report schemas against real work

Project: the backoffice, Laravel 10, PHP. Tests run on PHP 8.4 in Docker and on PHP 8.1 on the host. GitLab MRs, Jira tickets, a release branch. Sources: PSWS-1713, 1728, 1815, 2123 and MRs !29 and !37. Read only; nothing in the spec changed.

## Blockers for this project (fix before build)

1. **The stop check commits.** The owner's hardest rule here is "never commit or push without explicit approval of each operation". An agent stop that commits on the work branch breaks it.
   - Our commits also follow a house style that `crucible(build): …` can't express:
     - `fix(Actions): PSWS-2123 Report a stopped bulk delete`, with a Jira link;
     - signed, with `-s`, and one commit per ticket;
     - no AI or tool trailers.
   - `Job:` and `Effort:` trailers would leak tooling into company history.
   - Fix: crucible commits live only on an effort branch or worktree. The commit that reaches the ticket branch is made through the approved git flow, in the project's style. Alternatively the commit template is per project.
2. **Known failing tests.** The suite has 3 known errors (TranslationsImportServiceTest ×2, Feature ExampleTest). Every PSWS-1728 round reported "only the 3 known errors". Under the current rules every build and every plan here is blocked:
   - a `fail` gate needs a `gate_red` blocker;
   - a `fail` baseline needs a blocker.

   Fix: a `known_failures` list (test ids) on the gate and the baseline. A gate with only known failures counts as pass.
3. **One gate per kind is too few.** We run tests twice: PHP 8.4 (production) and 8.1 (host). Give a gate a `where`, as `run` already has, e.g. `{gate: test, where: php8.4}`.

## 1. Missing, and never used

**Missing:**
- **Deploy facts on the build report.** Two cases:
  - A new required Vault key (`backoffice_PLATFORM_API_KEY`, needed on UAT and PROD before release).
  - A destructive migration that drops 17 tables, so a rollback needs a DB restore.

  Neither is a gate, a decision or a `noticed`. They have to reach the release card. Suggest: `release_notes[] {kind: config|migration|infra, at, text}`.
- **Locations outside the tree.** Two cases:
  - A rollback note cited release 3.11.22's `app/Services/LogService.php:76`.
  - PSWS-1713's bearer header also reaches a related repo's existing routes.

  Draft 02 had `@where:` and `relates_to`. Rule 7 here drops both, so these findings can't be written.
- **Review `notes` and `out_of_scope`.**
  - Notes: "accepted documented deviation: recordingGateway() partially mocks the class" (PSWS-1728).
  - Out of scope: N-4 on !37 was pre-existing on main.
- **A note on `done`.** The re-reviewer, and the external "fixed in <commit>" reply, need what was done, e.g. "KeycloakService.php:313 now logs the 401 path". The rules forbid any text on `done`.

**Never used:** the build report's `questions` cap of 8; we never had more than 3.

**`found` masking:** the example shows a key prefix (`AKIA****`). Our rule is never to print a secret, any part of it, or its length; only its name and location. Show location and kind only. Example: the hard-coded LogMyCode token at `app/Services/KeycloakService.php:50` would be "hard-coded token, KeycloakService.php:50".

## 2. The section 12 questions

1. See above.
2. **`partly`:** not needed from the fixer if `done` can carry a note. The reviewer's `open` with a reason already covers "half fixed": item A on PSWS-1815 was reopened that way.
3. **Fixtures and support files:** plan support before tests. PSWS-1728 changed a base class (`assertAuditedOnce` gained a level argument, plus new helpers), which reached about 12 tests. A recorder-spy subclass was the seam for every audit test. The Keycloak tests use goldens with an update-golden env var. A challenger can't judge any of that if it only appears in the tester's report. Fixtures may stay reported, but a golden that will be re-captured should be planned.
   - **Keep `modify.keeps`.** PSWS-1728 repaired 78 tests in one round. `keeps` is the only thing that tells the challenger what a repaired test must still assert, which is exactly where the repair hazard lies.
4. **Realism classes:** workable. **`handoffs`:** used. On PSWS-1728 the code reviewer handed "audit integrity (forging a LogEntry)" to observability.
5. **External judgements:** not enough. On !37 one bot note held 9 findings:
   - N-1 was true but intended and documented;
   - N-4 was true but pre-existing on main;
   - on !29 the triage used LEGIT / NOT LEGIT / DISCUSS, and §9 and §10 said "no issue" themselves.

   That needs:
   - `judgement` per item, not per thread (`item` plus a short quoted title);
   - `intended` and `out-of-scope` judgements;
   - a `question` judgement for the human;
   - `info`, which needs no reply.

   Our replies were per item, under the one note, each headed by the item's title.
6. **Foreign review:** I have no real case. A separate author-facing `comment` sounds right: our MR replies were written for the reader, with the commit SHA, not as claim plus suggestion.
7. **Commits:** see blocker 1. `Fixes:`/`Declines:` with internal IDs mean nothing to the team. Our MRs are squash-merged, so the trailers are lost anyway. Keep `decisions` out of the body; the ticket and the MR body carry them.

## 3. Awkward on this stack

- **The worktree.** PHP 8.4 tests run in Docker mounting the primary checkout and its `vendor/`. A job in a separate worktree tests the wrong tree unless the mount follows the worktree. "Exists at the head the job worked on" assumes it does.
- **The challenge's four asks** (`add`, `change`, `remove`, `prove`) can't target a shared helper or base class. The earlier draft 03 allowed `file::helper`. Also no ask for `correct` (a wrong `guarded_by`).
- **The arbiter needs `ask`.** PSWS-2123 point 3 became a follow-up ticket on the user's decision; it was neither fix nor drop.
