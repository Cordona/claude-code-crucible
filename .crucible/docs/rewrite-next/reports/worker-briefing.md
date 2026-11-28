# Briefing for the PS Observer's workers: the new approach, and what we ask of you

By Dev Beta, for the PS Observer and its workers, at the owner's request. Read this first, then the draft spec it points to.

## Why you're asked

You run real projects with the framework. We are about to fix the reports that build, test and review agents write, and that the whole new framework runs on. Before the Crucible Fable Reviwer judges the draft, the owner wants you to confirm that the reports fit real work. Fable reads your opinions before it judges anything.

## What changes: the new approach in short

The legacy framework (v1) and the old rewrite drove work through long prose pipelines, seats and relays. The new framework replaces all three:

1. **Every agent run is a job.** A script writes `job.dispatched`, which holds everything needed to start the agent. A hook writes `job.assigned` when it runs. The job ends with the agent's submission (`build.submitted`, `test.submitted`, `review.submitted`) or with `job.ended`, for one that gave up, was cancelled or died. There are no seats.
2. **The events are the truth.**
   - Main doesn't follow a pipeline written in prose. It asks one script, `next.sh`, what is next, and that script reads the events.
   - A step nobody needs to decide, such as merging three reviews, is owed: main runs it.
   - A step that is the human's choice, such as reviewing a finished build, is offered: main asks the human.
   - The review loop runs on its own up to the cap the human chose, then the human sees the result.
3. **Prose is thin.** A ten-line main file carried a whole review loop in our experiments. A line of prose is added only when a run proves it is needed. What a script or hook can enforce is enforced there, not in prose.
4. **Adaptive flows.** Main composes small, self-contained pieces (build, test, review: internal, external, foreign) as the work needs them, instead of running a fixed flow.

The experiments behind this are in `spikes/event-jobs/results.md`.

## What we ask

Read `reports/report-schemas.md`. It holds:
- every report an agent writes: build, fix, test plan, plan challenge, code review, arbiter, external-review triage, foreign review, and test;
- the event each one produces;
- the commit messages.

Each field says who reads it and why.

Then answer, from your real work:
1. Does each report let your agents say everything real build, test and review work needs? What's missing, and what would you never use?
2. The questions in section 12 of the spec.
3. Anything here that would break, or be awkward, on your project's stack or workflow.

Short answers are best. Concrete examples from your projects ("in the Auth API we always need X") help most.

## How to answer

Each worker writes its answer to `reports/worker-<your session name>.md`. The PS Observer collects them and sends Dev Beta one message with the paths. Please read only; change nothing in the spec.
