# Jobs, steps 2-4: kinds, dispatch, assign, and the rewire (design, for Fable, then the owner)

2026-11-27. Owner's ask: add the test and review kinds, the agent dispatch and the job assignment, then rewire and test defining, dispatching and assigning for build, test and review. Built on step 1 (`specs/jobs-1-defined.md`, `jobs/define/`). Proven in `spikes/dispatch/` (native plugins 10/10, stress2: 47 jobs, 34 agents, 3 repos). Principles: floating pieces, one act per script, DRY, simple; prose thin.

## End state (what is left when this lands)

| Piece | Today | After |
|---|---|---|
| `jobs/define` | job.defined, build kind | + `kinds/test.json`, `kinds/review.json` |
| `jobs/start` (new) | — | the door: checks a job and prints main's exact Agent call or SendMessage; the agent files; the start and send hooks; `agent.initialized` |
| `agent-jobs` | job.dispatched, job.assigned, ended/stalled/refused, lookup, iteration.jq | **retired, the folder deleted** (owner, 2026-11-27). job.dispatched and iteration.jq go; the rest moves into the `jobs/` group: job.assigned (reshaped `{job, agent, tree}`, written by the start hook cold or the send hook hot) into `jobs/start`; job.ended/stalled/refused, the lookup (job-of.sh, agent-job.sh, jobs.jq), the Stop hook that ends gone jobs and end-job.sh into `jobs/track` (installed `jobs-track`), reading job.defined |
| agent hooks and report rules (`agent-submission`, the three agents' libs and facts) | read the job through job-of.sh / jobs_dispatch | **unchanged**: job-of.sh keeps printing the same job view, now built from job.defined + job.assigned + worktree.cut + agent.initialized (one adapter, no cascade) |

Net: one job model, not two; one iteration count.

## The new kinds

`kinds/test.json`: agent code-tester; refs context (required), spec, grills (list), plan (required: `test-plan.submitted` or `test-plan.updated`, the latest); tree `use` only; write scope tree.

`kinds/review.json`: agent code-reviewer; refs context (required), spec, grills (list); tree `use` only; write scope report; resolve fills `work.range` from the tree (base: its worktree.cut base; head: the tree's HEAD at resolve).

A ref may name more than one event type (plan). Iteration: a build opens the next on its tree; every other kind takes the tree's current one (resolve fills, the rule checks at the write). Only build opens an iteration: a domain fact, kept in the shared count, not a per-kind file field.

## The door: `jobs/start/scripts/main/job-start.sh --effort E --job SEQ [--hot AGENT] [--tree SEQ]`

Checks, then prints the one call and leaves the note the hook matches it by:
- the job is defined, not assigned, not ended;
- its tree: `use` → that worktree.cut; `cut` → `--tree SEQ` names the worktree.cut main made with `worktree-cut.sh` (same repo and from, no other job's cut);
- one open writing job per tree (a second writer refused; a reader gets one line naming the open writer);
- cold: writes the kind+set agent file if missing (base agent + `skills:` = the job's plugins and the base's own skills), prints the Agent call (`subagent_type` the agent file, `run_in_background`, `isolation: worktree` when on code, prompt = the job: kind, seq, report path, tree, and what the kind's agent needs);
- hot: the agent is initialized, same base, its plugins cover the job's, no open job, and it stands in the job's tree (invariant 9); prints the SendMessage.

Hooks (registered through `jobs/start/hooks/matchers.json`):
- PreToolUse Agent: a job agent's start must be a door note; one per message.
- WorktreeCreate: answers the job's tree path.
- SubagentStart: `agent.initialized {agent, base, type, plugins}` and `job.assigned {job, agent, tree}`.
- PostToolUse SendMessage: hot `job.assigned`.

## The rewire: one adapter

`job-of.sh` and `jobs.jq`'s `jobs_dispatch` (moved to `jobs/track`) keep their output: `{job, state, kind, agent_type, tree, report, known_failures, iteration, setup, ...}`. They now build it:
- kind, setup (= plugins), iteration (= work.loop.iteration), payload fields from job.defined;
- tree: the path of the worktree.cut job.assigned names;
- agent_type: the base, from agent.initialized (the hooks see the generated type; they map it to its base through agent.initialized, so `${skills}/<base>/submissions` keeps working);
- report: `reports/<kind>/<seq>.json`, as today.

So `agent-submission`, the report rules and the facts scripts change only where they take `agent_type` from the hook's stdin (one lookup: type → base), and in the paths and includes that named `agent-jobs` (now `jobs-track`).

## Blockers for the owner (before any real agent runs)

1. **The plugins can't load as they are.** All 17 real plugin skills have `disable-model-invocation: true`, and Claude Code then silently skips them in `skills:` (proven in the native-plugins spike). The plugin change you haven't approved yet (model-invocable, short descriptions) is needed first.
2. **Where agent files live:** user-level `~/.claude/agents` (recommended: works from any repo) or the project's `.claude/agents` (only the repo main stands in). Never the owner's real `~/.claude` in validation: the run uses a scratch config.
3. **Known failures and the other payload fields** job.dispatched carries (known_failures, plan, earlier, base/head, cover, threads, foreign): for build, test and review this step carries known_failures and plan as input refs or work fields; the rest wait for their kinds. Shape for the owner.

## Validation (live, interactive, auto mode, scratch config)

Stand-in-free: the real code-builder, code-tester and code-reviewer on a small repo, opus, as the job model's runs did.
1. A build defined, its tree cut, started cold through the door: agent.initialized with its plugins byte-equal, job.assigned to its tree, build.submitted through the unchanged hooks.
2. A test on the build's tree (use), cold; a review on it, cold; then a second review hot on the same reviewer.
3. Refusals: a second writer on a tree; a hot job to the wrong base or plugins; an Agent call not from the door; two starts in one message; a hot job to an agent in another tree.
4. The regression runs (agent-jobs, build-agent, test-agent, review-agent) pass on the adapter, with job.dispatched gone.

## Phases

1. Kinds (test, review) + resolve's multi-type ref and range. Script runs.
2. The adapter: job-of.sh/jobs.jq on the new chain; job.dispatched and iteration.jq deleted; the four regression runs moved onto job.defined.
3. `jobs/start`: door, agent files, hooks. Script runs, then the live run.

Questions for Fable: is the adapter the right seam (vs moving every reader)? Is `jobs/start` one piece or two (door vs hooks)? Anything here growing the complexity the owner worries about?

## After Fable's review (reports/jobs-2-4-dispatch-fable.md), applied

- **The view is a contract:** job-of.sh prints "what the agent side may know about a job", written down in its --help, not job.dispatched's body.
- **Agent files leave the door:** a new agent file is seen only from the next turn, so `jobs/start/scripts/main/agent-files.sh` writes them when the card is shown (its own act); the door only refuses a missing one.
- **job.assigned's rule moves to `jobs/start`,** beside its writers.
- **One way to the base:** a generated agent type is `<base>-<set>` (code-builder-kotlin-spring-security). The hooks' cheap first test stays cheap: an installed `<base>/submissions` folder whose name prefixes the agent type, with no event read. The base then comes from the open job's kind file (`agent`), never from agent.initialized.
- **No "latest" plan:** a test names its plan's seq; resolve checks the type (test-plan.submitted or test-plan.updated).
- **Order:** phase 2 (rewire) and phase 3 (start) land together for the regression runs: they assign through the start hook's writer, not job.dispatched.
- **The prompt stays as small as today;** `jobs/start/SKILL.md` goes to Fable before it runs.
- **Pass line:** about one Agent call per job. A ledger of files deleted vs added comes with the build.

Owner, 2026-11-27: the plugins become model-invocable with short descriptions; agent files are user-level (`$CLAUDE_CONFIG_DIR/agents`); known_failures stays, as `work.known_failures` (A).

**known_failures** is a list of check names known to fail before the job; the builder's and tester's report rules accept those failures without a blocker. Options: (A) `work.known_failures: [names]`, given by main, shown on the card: today's behaviour, kept; (B) dropped: every red check is a `gate_red` blocker. Beta's lean: A.
- **The move apart from the adapter (Fable, section 6):** first the adapter with every path untouched, regression runs passing; then the move to `jobs/track` and `jobs/start` as paths only, no behaviour change, the same runs passing again. End check: no file names agent-jobs, in code, comments or prose; then the folder is deleted.
