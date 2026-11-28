# The test agent: brief for the Fable Reviwer

By Dev Beta. The owner asks you to check the tester's slice and the owner's suggestions from reading it. Talking only; the owner's go is the only go.

**The slice:** `reports/test-agent.md`, the tester's spec, shaped like `build-agent.md`. It reuses the builder's stop hook, slim events, working commit, iteration and readiness check.

## The owner's points from reading it, with my reasoning

1. **Tests with different fields looked like an overlook.**
   - **Intentional:** each `action` has its own fields. `add` has `level`, `why` (unit and integration), `guards` and `breaks_on`; `modify` has `changes`, `keeps`, `guards` and `breaks_on`; `remove` has `covered_by`.
   - **One real gap:** `modify` has no `level`, though the card counts tests by level.
   - **Proposal:** `level` on `modify` too, and a table per action in the spec.
2. **The test report looked like it misses build-report fields.**
   - **Intentional:** it has every build-report field (summary, gates, decisions, impact, noticed, questions, blockers). The examples leave out the empty ones, by the prune rule.
   - **Proposal:** say so explicitly, and show a fuller example.
3. **Report names** (the owner's suggestion: `reports/<kind>/` or `reports/test_report_21.json`).
   - **Proposal:** one folder per report kind, named after what the report is, matching its event:

     ```text
     reports/build/2.json                  build.submitted
     reports/fix/17.json                   fix.submitted
     reports/test-plan/21.json             test-plan.submitted (the draft)
     reports/test-plan-challenge/23.json   test-plan.challenged
     reports/test-plan-update/25.json      test-plan.updated (the rework)
     reports/test/31.json                  test.submitted
     reports/review/40.json                review.submitted
     ```

     The kind shows in the path, each folder holds one shape and one check, and the number stays the job's.
   - **It changes the builder,** already built with `reports/<n>.json` (the pin and the view accept only that), so both slices change.
4. **The rework becomes its own job kind, `test-plan-update`.** Today it is a `test-plan` job with challenges attached, so its report could not be told apart from a draft's.
   - As its own kind, it gets `test-plan-update-submission.json` and `test-plan-update-report-validation.sh` (the owner's one-file-per-kind rule), and its folder follows from the kind with no special case.
   - The challenge's kind (written by the challenger) would then be `test-plan-challenge`, in the reviewer's slice.

## Also open in the slice (`test-agent.md` §10)

1. **`plan` in `test.submitted`:** a link, stamped from the job, to the approved plan the tests were written from.
2. **The plan challenge's report and its check** belong to the reviewer's slice, since a review-type agent writes it.
3. **What a tester may change:** only the plan's test and support files. Anything else is production, refused.

## Questions

1. Do the owner's points 1 to 4 pass your reader test and the constitution? Anything to change?
2. §10's three open points.
3. Anything else in `test-agent.md` that drifts from the builder's agreed design, or from the old rewrite's tester and plan rules?

Please answer in `test-agent-fable.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines.
