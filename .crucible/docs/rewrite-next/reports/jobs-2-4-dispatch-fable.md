# Jobs, steps 2-4: kinds, the door, assign, the rewire. Fable's review (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `specs/jobs-2-4-dispatch.md`. Step 1 as built: `jobs/define/` (`job.defined.jq`, `kinds/build.json`, `SKILL.md`). In `agent-jobs`: `job-of.sh`'s contract, `jobs.jq`, and the list of files that read a job.

**Not done:** nothing was run. I did not read step 1's scripts line by line, the agents' facts scripts, or the installer.

## Verdict

**The design is right, and it removes more than it looks:** one job model in place of two, one iteration count, and the agent side untouched.

**On complexity, the owner's worry: three places where this design grows more than it needs to,** and one gap that has to close before the adapter is built. With those, I'd call it lean.

| Question | Answer |
|---|---|
| Is the adapter the right seam | **Yes.** Section 1 |
| `jobs/start`: one piece or two | **One piece, minus the agent files.** Section 2 |
| Is complexity growing | **In three places.** Section 3 |

## 1. The adapter: the right seam

**It isn't a new layer; it is the seam that already exists.** `job-of.sh` calls itself "the one reader of job.dispatched", and about thirty agent-side files reach a job only through it or through `jobs.jq`. Changing what that one reader reads, and nothing downstream, is what it was built for. Moving every reader instead would touch all thirty for no gain.

**One caution: the view is now a contract, so treat it as one.** After this step the job view (`agent_type`, `setup`, `tree` as a path) no longer mirrors any event. That is fine, and it is good decoupling. But then it should be described as "what the agent side may know about a job", not as `job.dispatched`'s body. Otherwise the old event lives on as a ghost in the comments and the next reader looks for it.

**The gap that must close first: blocker 3.** The view prints `known_failures`, and the agents' scripts read it and the other payload fields. `known_failures` is a list of names, not an event, so it has no home in `input_refs`, and `work` is the tree, range and loop. Until the owner settles where it goes, the adapter has nothing to build that field from. This is a decision before phase 2, not before the live run.

## 2. `jobs/start`: one piece, with one thing taken out

**The door and its hooks belong together.** They share the note the door leaves and the hooks match. That note is a private agreement between them; two pieces would make it a public one.

**Take the agent files out of the door.** Two reasons:
- **It was settled otherwise, on evidence.** The native-plugins runs showed a new agent file exists only from the next turn. So the files are written when the jobs are shown for approval, and the door only reports a missing one ("exists from the next turn"). As drafted, the door writes the file and prints a call that can't work in the same turn.
- **It is a second act.** The owner's line was distinct scripts, not one that checks, writes files and prints. Writing an agent file from a base and a plugin set is its own small script, called at the card.

**Where `job.assigned` lives.** After this step its two writers are `jobs/start`'s hooks, and its rule stays in `agent-jobs`. Move the rule to its writers. Then `agent-jobs` holds what ends a job and the lookup, and each of the three pieces says one thing: define, start, and the state of a job.

## 3. Where complexity grows more than it needs to

**1. Two ways to learn an agent's base.** The spec maps the generated type to its base through `agent.initialized`, for the hooks. But a hook that has the agent's open job already has its kind, and the kind's file names the agent. One source is enough: the base comes from the job's kind. `agent.initialized.base` then serves only the hot check at the door.

**2. "The latest" plan.** A ref that takes two event types is a small, real need (the owner kept test-plan and test-plan-update apart). "The latest of them" is a rule on top. Main names the plan's seq; resolve checks its type. Add "latest" when a run shows main picking a stale plan.

**3. The cheap first test in the agent hooks.** Today every Write or Edit by any agent is dismissed by one folder test on the agent's type. With generated types that test no longer works, and the replacement must not become an event read on every tool call of every agent. Say in the spec what the cheap test is.

**What I checked for and did not find:**
- **No new event beyond the approved ones.** `agent.initialized` in, `job.dispatched` out.
- **No new rule for main.** The door prints the call; main sends it.
- **"Only build opens an iteration", kept in the shared count:** agreed. It is the simple answer to the question I left open, and a per-kind field for one kind would be machinery.
- **Four hooks:** each was needed and proven in the spikes.

## 4. Smaller points

- **After each phase the framework must still run.** Phase 2 deletes `job.dispatched` before phase 3 brings the door. Say how a job gets assigned in the regression runs between the two, or swap the order.
- **The prompt.** "What the kind's agent needs" should stay as small as today: the agents pull their inputs through their own scripts and the view. The prompt names what the agent can't find itself and nothing of the plumbing.
- **Prose.** If `jobs/start` gets a `SKILL.md`, I'd like to see it before it runs. The door's printed lines are most of it already.
- **The live run depends on blocker 1.** Real agents can't load plugins until the plugin change is approved. Phases 1 and 2 don't wait for it.

## 5. One number to keep the worry honest

**Add a short ledger to the spec:** what this step deletes and what it adds (events, scripts, hooks, lines of prose main reads). And one pass line from the stress runs: about one Agent call per job, and no line of prose telling main how to start a swarm. If the ledger grows without the pass line holding, that is the complexity the owner means.

## 6. Addendum: `agent-jobs` retired, `jobs/track` added

**Agreed.** It is where section 2 was heading: `job.assigned` with its writers, and one home for job things (`jobs/define`, `jobs/start`, `jobs/track`) instead of two. Three pieces, each one thing: what a job is, how it starts, what state it is in.

**One cost to name: "the agent side unchanged" no longer holds as written.** About thirty agent-side files name `agent-jobs` in a path (`include "agent-jobs/scripts/lib/jobs"`, `agent-jobs/scripts/internal/agent-job.sh`). The move changes that path in every one of them. It is a rename and nothing more, but it lands in the same files the adapter was meant to leave alone.

**So keep the two changes apart:**
- the adapter changes what the lookup reads, with paths untouched; the regression runs pass;
- the move changes paths only, with no behaviour change; the same runs pass again.

Done together, a failing run can't say which of the two broke it.

**And one check at the end:** no file still names `agent-jobs`, in code, comments or prose.

## 7. For the owner

1. **Where `known_failures` and the other payload fields go** (blocker 3). Needed before phase 2.
2. **The plugin change and where agent files live** (blockers 1 and 2), both still open from the spikes. The three-repo run argues for a place that doesn't depend on the repo main stands in.
