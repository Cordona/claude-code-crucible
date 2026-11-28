# Report schemas: decisions

## 2026-11-24, the owner (after round 1: the workers and `schemas-fable.md`)

1. **A working commit is covered by the build's approval.**
   - When a build, fix or test job's report validates, the stop check commits the tree in the effort's own worktree, on the effort's branch.
   - Working commits never land. What lands is made later by the gated git step, per operation, in the project's style. That step has its own spec, the landing step.
2. **Declines are the human's to settle, at the end card.** This replaces D10's automatic accept/insist and arbiter.
   - Every finding in a fix job was chosen by the human, so a decline overrides the human's choice.
   - The loop keeps running unattended. A declined finding is set aside, and the next reviewer gives its view on the decline.
   - The end card shows each decline with the fixer's reason and the reviewer's view, and the human waives it or sends it back to be fixed.
   - The arbiter is no longer an owed round; main may offer it, and its ruling is a third view on the end card.
3. **Working commits are not signed.** Nothing reads their signature, and they never land. Signing belongs to the landing commit, with the developer's own key.

## 2026-11-24, Fable's round 2 (`schemas-fable-2.md`), applied to draft 2

- **A re-sent decline:** an ID the human sent back after a decline can't be declined again. The fixer writes a blocker instead.
- **The arbiter:** its event is `ruling.submitted`, since no merge follows a ruling. When to offer the arbiter is left to main and the human.
- **Dropped:** `untested.category`. `impact` and `not_run` are out of the build event; the card reads them from the report.
- **Challenge targets** may be a support file the plan names. In a triage, every thread is judged at least once, and items are the agent's own split.
- **Small fixes:** rule 0.4 says "a step that decides". The plan uses `blockers`, as the build report does. The 55-character cap is for the working commit's subject. The rule against customer data lives in each agent's prose.

## 2026-11-24, the owner, for the review-loop spec (next, after the reports)

- **`round.made` becomes `review-round.opened`.**
- **The offer names the work by its commit's first line,** not a seq: "add a retry limit to the upload client: review it?". The same goes for tests.
- **To design in that spec:**
  - the review gate card, where the human approves the reviewers and their lenses;
  - the merge event (`review.merged`), and its name.

## 2026-11-24, the owner, on Fable's build-agent verdict (`build-agent-built-fable.md`)

- **The job's setup follows the old rewrite's rule** (`flow-code-agent-dispatch`):
  - exactly one language;
  - frameworks optional, zero or more, only with a language;
  - at least one standard, and a tester always gets `standard-testing`.

  This replaces the built rule, which required a framework.
- **Missing framework files** (an agent's `<kind>-submission.json` or `<kind>-report-validation.sh`) are a readiness fault. The install check (`install-check.sh`) checks them once, at install. At run time the hook's refusal goes to the human, never to the agent as a repair line.
- **Deferred until the whole framework is ready and in use:** reading less of the event log.
  - **The owner's idea:** a checkpoint event saying "events 1 to N are settled", after which readers start from N+1.
  - **The first step,** for the dispatch talk: read only the session's own effort, not every effort.

## 2026-11-24, the owner, on the tester's slice (`test-agent-fable-2.md`)

- **Reports stay as generic as possible.** Specific fields bite. A case a worker raises gets free text in an existing field, or a gate, before it gets a new field; a new field needs a script or card that treats it differently.
- **Mutation testing is a gate:** `mutation`, with the usual results:
  - `pass`, with a note such as "34 breaks, all caught";
  - `fail`, with what survived;
  - `not_run`, with why.

  A test report always lists it, run or not. No per-test mutation fields.
- **Fable's verdict is applied to `test-agent.md`:**
  - §5 now follows the approved plan: the planned file wins; a file the build changed is refused if unplanned; anything else needs a `decisions` entry;
  - `production_bug` may point anywhere outside the plan's own files;
  - `covered_by` may be `nothing: <why>`;
  - `names` on modify and remove;
  - `guards` is optional on modify;
  - a support entry may name a folder;
  - the `run` examples use a filter.

## 2026-11-24, the owner, on the reviewer's words

- A reviewer gives **verdicts**, and a fixer gives **answers**.
  - The re-review's `answers` become `verdicts`, each `{id, verdict}`.
  - The external review's `judgement` becomes `verdict`.
- The review's overall result, filled in by a script, is named `outcome`, so it doesn't collide with `verdict`.
- **The fixer gives a resolution** (done, partly or declined) per finding: `resolutions`, each `{id, resolution}`. A resolution is what the fixer says it did. The reviewer's verdict decides (Fable).
- **The words stay distinct:** `ruling` stays the arbiter's word, and `outcome` matches the core flow's end word.
- **A plan update still gives `answers` to challenges** (applied, cannot), on purpose: a challenge carries an `ask`, and is answered.

## 2026-11-24, the owner, later: the words replaced

This replaces verdicts and resolutions above, which the owner found courtroom-like.
- **The fix report:** `fixes`, each `{id, status: done|partly|declined}`.
- **The re-review report:** `findings` (new) plus `fixes`, each `{id, status: fixed|open|agree|disagree}`.
  - The same key as the fix report, told apart by the report's kind.
  - `agree` and `disagree` are the reviewer's view of a decline, not a state of the code.
  - The first review has no `fixes`.
- **The external review keeps `verdict`** per point.
- **`outcome` is dropped.** The round's merged result belongs to the review loop's spec. If it gives a merged finding a status, it uses the same words (open, fixed) (Fable).
- **`status` is no longer a reserved key.**
- **Finding IDs reset when a new iteration starts** (`<LENS>-NN`, unique in the iteration). The real key is iteration + ID.
