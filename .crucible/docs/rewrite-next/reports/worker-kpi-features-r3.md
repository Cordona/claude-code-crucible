# Worker answer, round 3: KPI features (core-api)

Same stack as round 1: PHP/Laravel, one DB per tenant, PHPUnit in Docker, GitLab MRs with human and bot notes. Draft 2 already fixed my round-1 breakers (separate working commits from landing, `where`, `narrowed`, `deferred`/`answered`, `keeps`, `support`).

## 1. One `noticed` with `security` and `for`: fits, with two conditions

- **The floor can't rest on an optional flag the agent may forget.** Our real leak (an internal host committed in test goldens) is exactly the thing a builder writes as an ordinary "noticed, outside this task". Under `found` the kind had to be chosen. Under `noticed`, leaving out `security` silently drops it to "a count, full on ask". Keep a required choice: either the stop check asks for `security` on every entry (`true`/`false`), or it scans `text` and the `at` lines for secret/host/customer-data shapes and refuses an unflagged hit.
- **Keep the kind, not just a bool.** `security: "secret" | "instruction"`. The response differs: a secret means rotate or remove, while instruction-shaped text (a Jira comment or MR note telling the agent what to do) means never follow it. We meet both. Customer data counts as `secret`, and `text` never carries the value.
- `for: "<lens>"`: fine. It's how a PHP review passes a raw query or a migration to persistence/security.

## 2. Test-plan event names: fit

`submitted` / `challenged` / `updated` / `approved` read correctly. One gap: at our plan gate the human sometimes edits the plan ("drop T-3, add a re-submit case"). Say whether that is a `test-plan.updated` by main before `approved`, or `approved` with the edits. Otherwise the tester's "exactly the approved plan" has no single source.

## 3. No `files` in `build.submitted`: fits, if the working commit is scoped

Reading files from the commit is right. The risk is what goes into the commit. Our test runs write about 25 generated files into `storage/app/` that sit untracked in the tree. A stop check that stages everything sweeps them in, and then "files from the commit" is wrong, and so is the review cover. The stop check must stage only what the job changed (diff against the job's start, minus untracked files that were there before it began), never `git add -A`.

## 4. `report` path back in every event: fits

No objection. It's what the reviewer job needs to find the builder's `decisions`.

## 5. Finding inside its item: fits, plus one case

On our MRs the AI-review bot and the human reviewer can flag the same defect in two threads. With nested findings that becomes two findings, two fixes and two IDs. Add `same_as: "<item>"` on a `valid` item. Its finding is then the other item's, fixed once, and both threads get the reply. A bot note that bundles several defects is already handled by splitting it into items.

## 6. `answers` keeps its name: fits

The kind of job already separates the fixer's values (`done`/`partly`/`declined`) from the reviewer's (`fixed`/`open`, agree/disagree). One name is fine.

## Timeline

It matches how we work, and its terms match draft 2 (`partly`, `noted`). Our one real-world addition is in §4, step 6: a reply to a human question like "prod tonight or preprod first?" is a release decision. It must stay the human's at the replies gate, and the agent never decides it.
