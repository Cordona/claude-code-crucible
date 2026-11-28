# Worker answer: KPI features (core-api, PeopleSpheres)

Stack: PHP/Laravel, one PostgreSQL DB per tenant, PHPUnit in Docker (never the full suite), GitLab self-managed MRs, Helm values via Flux, Jira. Examples are from PSWS-2236 (counting form completions), its Helm MR, and PSWS-935 (import errors).

## 1. Does each report fit real work?

**Build report: mostly yes. Missing:**
- **Where a gate ran.** Our PSWS-2236 tests could not run locally (the local image is too old, and the registry login failed), so the green gate was the MR pipeline. `gates[]` needs `where: local | ci` plus a pipeline ref, or `pass` claims too much.
- **`narrowed` is the normal case here, not the exception.** We only ever run `--filter`. Keep it, and allow the filter in `note`.
- **Deploy facts.** Real changes need a per-env floor value, an env var on 4 workloads, a post-deploy backfill command, and a human-only migration step. None of those are decisions, questions or blockers. Today they go into a deploy checklist. Add `deploy: [{env?, text}]`, or say plainly that `noticed` holds them.
- **`found.kind` is too narrow.** Our real leak was an internal host/IP committed in test goldens, plus the standing risk of tenant rows in output. Add `infra` (host/IP/cluster name) and `customer-data` next to `secret` and `instruction`.
- Never used: `request_unclear` blockers. We ask in the main thread before dispatching.

**Fix:** fine (see Q2). **Test plan:** needs fixtures and `keeps` (Q3). **Review:** fine. **Arbiter:** an `ask` ruling is needed. Product calls like "count re-submits or not" came up and were never fix-or-drop. **Test report:** a `test`-only gate is too narrow. We also run `format` (`php-cs-fixer-on-changes.sh`) on test files.

## 2. Fix: `partly`?

No `partly`: `done` plus the reviewer's `open` covers it. But add `deferred` with a `ticket`. We often agree a finding is real and file it as a follow-up ticket instead of fixing it in this MR ("fix only the reported bug" is a standing rule). `declined` reads as a disagreement, which is wrong here.

## 3. Test plan: fixtures first?

**Yes, for us.** Tests need a tenant-DB fixture, a factory chosen per case (every form assignment must come from a trigger, which changes the setup), and golden files. A plan that hides these hides half the work, and the challenger can't see that a fixture makes a test meaningless. Keep `fixtures` as planned items. Also keep `modify.keeps`: our repairs to golden and import tests are exactly where an assertion silently weakens. `baseline` must allow `narrowed`, since we never have a full-suite baseline.

## 4. Review: realism and handoffs

Three classes and their proof rules: workable. They match how we already gate. `handoffs` are used rarely but for real: a PHP review that sees a migration or a raw query hands it to persistence or security. Keep it.

## 5. External review: three judgements enough?

**No.** On real MRs, the most common thread is not a finding at all. The reviewer approved and asked us to merge, warn QA, and choose prod-tonight or preprod-first. Add:
- `answered`: a question or request, with a reply and no finding;
- `deferred`: valid, but goes to a follow-up ticket (link in the reply).

Our MRs also carry an AI-review bot's notes next to the human ones. Human threads should be triaged first, so a `source: human | bot` stamp (script-derived) would help.

## 6. Foreign review: a separate comment?

Yes. Comments go to colleagues, sometimes in another language, and the tone differs from `claim`. Add an optional `comment` field and build from `claim`/`suggestion` only when it is absent.

## 7. Commits: trailers and body

**This is where it would break on our project:**
- **Auto-commit by the stop check conflicts with our hardest rule:** no commit without the owner's explicit go, per operation. The job model must allow "commit planned, not made" (submit the tree diff and let main commit after consent), or it can't run here.
- **The subject format clashes with the repo convention.** Ours is `fix(import): PSWS-935 name the reason an import row failed`: the project's scope plus the ticket key. `crucible(build): …` would be rejected in review. The subject needs the project's type/scope and a ticket from the job.
- **`Job`/`Effort` trailers in a client's GitLab history leak framework internals.** The owner already strips session trailers. Make the trailers opt-in per repo.
- **Recovery by the `Job` trailer fails after squash or rebase.** Our MRs are squash-merged and then cherry-picked to a release branch, and a server-side rebase dropped our signature (`signed: false` after the fact). Don't rely on the commit SHA or trailer surviving the merge.
- **Decisions in the body: yes.** We already write the *why* into commit bodies, and git is the only record that outlives a pruned effort.

## Other stack friction

- Every `at` must exist at head. Fine for code. Our Helm change lived in another repo, so cross-repo jobs need the tree named per location.
- Tenant data is read-only and aggregate-only. Any report text field that could carry query output should be covered by the same `found` check, not just secrets.
