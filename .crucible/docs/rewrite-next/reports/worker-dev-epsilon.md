# Dev Epsilon (Auth API): report schemas vs real work

Source: auth-api, PHP 8.1 + Laravel + PHPUnit, GitLab MRs, the partner API epic. Legacy framework runs: build/fix loops of up to 9 rounds (PSWS-1792), lens passes, 7 test plans, MR reviews by a human and an AI note.

## 1. Fit, missing, never used

### Commits (§10): the biggest problem for this repo

- **`crucible(build): …` breaks the repo's convention and its release tooling.** auth-api commits are Conventional Commits with the ticket in the subject (`fix(partner-api): PSWS-2357 …`), and the repo runs release-please on them. `crucible` is not a type it knows, so these commits would be missing from the changelog.
- **The stop check auto-commits, but the standing rule here is: no commit without the human's explicit go,** reviewed first. Fine if these commits stay on a local effort branch and are re-made by a separate, gated step before anything is pushed. Say so, or this repo can't use it.
- **`Job:` and `Effort:` trailers** are local workflow ids in a shared repo's history. Our rule for tickets and MRs is "no local paths or register ids". Keep them on the local branch only.
- **One commit per job loses the atomic split.** For example, PSWS-1951 shipped as several commits, one per change, so changes 8–16 could be dropped one by one.
- **The body is needed: put `decisions` in it.** Ivo reviews from the commit body, and the 12-layer decode cap's reason (PSWS-1792) lived only there.

### Build (§1)

- **`gates`:** fits, but `narrowed` is the norm, not the exception. Agents ran targeted PHPUnit groups, and the full suite (about 1,100 tests) was run once at the end, sometimes only by the human. `note` should say which group ran.
- **`found` "AKIA****":** keep no prefix and no length. Our rule never prints any part of a key or its length.
- **Missing: a location outside the tree.**
  - Our docs fact-checks cited core-api code.
  - The 02 spec has `@<where>:path` and general findings with no `at`; this spec dropped both. "Must exist at the head" refuses them.

### Fix (§2)

Q2: `partly` is needed. Real answer: "fix 1–3, re-check 4". With only `done`, the reviewer must discover the gap; with `declined`, the part that was done is lost.

Decline of a human-chosen item: the spec sends it to the reviewer. In legacy, "what the human chose is mandatory": a decline stopped for the human's waiver. The human should see it, not only the reviewer. (No real decline of mine; this is a rule point.)

### Test plan (§3)

- **Q3, support:** must be planned.
  - 1793: "one core-api stub per test, never in setUp" (Laravel 9 answers with the first matching stub).
  - 1792: an AuthApi container swap.
  - Both were challenged before writing, so the challenge needs something to target.
- **Q3, fixtures:** fine to report only. auth-api fakes HTTP inline and has no goldens.
- **`modify.keeps`:** keep it. It's the anti-weakening line. 1951 had 12 repairs, and 1793 repaired 9 PartnerKeyCheckTest cases.
- **`move`:** never used.
- **`remove` needs `covered_by`.** 1951 deleted about 65 tests, and the human couldn't tell what still covered them.
- **`baseline: "pass"` is too thin.** 1951 started with about 570 failing epic tests. A count and the failing group are needed.

### Plan challenge (§4)

- **The four asks lose what 03 already settled:**
  - merge (2294: two drafts merged into one renamed test);
  - correct (1793: the run scope and the shared setup);
  - add on a behaviour the plan doesn't list (1793 test 7: the editor guard at a code line, with no `B-` to target).
- `target` must be a plan ID, so the most valuable challenge gets refused.

### Review (§5)

- **Q4:** the three realism classes are workable.
  - We used proof lines like "can't occur: Guzzle always sets request_size" (vendor file:line).
  - An edge-case HIGH (PHP-011) was fixed on the human's pick.
- **Q4, handoffs:** used.
  - 1792: "Handoff: file and fix it".
  - 1951: the security lens flagged a DB header carried over a redirect. Its owner was the human's restore decision, not a lens.
- **Missing, all settled in 02:**
  - `out_of_scope` with proof. 1792: ">1000 query params gives a 500 on every route" became a follow-up.
  - `notes` ("what held up"; the human approved on them).
  - `relates_to` for a finding outside the diff.
  - general findings with no `at`.

### Arbiter (§6)

Add `ask`. One real decision belonged to a stakeholder: the key format was "still needing his yes".

### External review (§7)

- **Q5:** the three judgements aren't enough.
- **Missing judgement 1: valid but a follow-up.** It's true, but not for this MR.
- **Missing judgement 2: confirmed, no change.** Ivo's note 11370 held 1 finding plus 4 "checked, no change needed" items.
- **Missing: an item within a thread,** since one note holds several findings.
- **Missing: the MR description as a target.** Ivo's finding was about the merge note in the description.

### Foreign review (§8)

Q6: no real foreign review. As a guess: yes, a separate `comment`, because the tone for an outside author differs from an internal claim.

### Test report (§9)

- **Only `test` as a gate:** fine for auth-api.
- **Missing: mutation verification.** Real report: "broke the production code in 34 ways, every break was caught". The test reviewer relied on it.
- **Missing: repair vs authoring,** answered per half.
- **Missing: the full-suite result, and where it ran.** 1951 ran it in scratch copies only, never in the worktree.

## 2. Stack and workflow awkwardness

- **GitLab, not GitHub:**
  - MR notes and discussion ids;
  - fast-forward merges with `squash=false` pinned to the head SHA;
  - a fix push resets an approval (`79edd92` on !32).
- **The main checkout holds someone else's uncommitted work.** All agent work runs in separate worktrees, so "the tree" must be the job's worktree, never the repo root.
- **Shared release branches (release-v3.12, release-v3.13) are cherry-picked by humans and other sessions.** A signed `-x` pick is a commit no build job made. Recovery by the `Job:` trailer must tolerate commits with no trailer.
- **The commit identity is the human's signing key,** not an "effort identity". Our commits must be signed by the developer's own key for the MR to be accepted.
