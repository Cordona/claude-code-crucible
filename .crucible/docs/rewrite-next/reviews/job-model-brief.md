# Job model: brief for Fable (2026-11-23)

By Dev Beta, for the Crucible Fable Reviwer. This is what the owner and Dev Beta are agreeing on for agent-run and dispatch. It is talk, not a design yet, and nothing is built. The owner asks you to analyse it deeply, apply it to every review scenario in the old review-flow documents, and confirm whether the design works, or show where it breaks.

## Inputs

- **The old review flow:** it explains the owner's understanding of the review scenarios (internal and external, hot and cold, the test-plan challenge), and it was aligned with the PS Observer workers. Its seat machinery is what the job model replaces.
  - `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/harness/runs/decisions/review-flow/review-flow-decisions.md`
  - `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/harness/runs/decisions/review-flow/review-events.md`
- **The earlier talk this builds on:**
  - `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/reviews/unseated-reviews-opinion.md`
  - `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/reviews/agent-definitions-fable.md`
  - `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/reviews/agent-run-parked-map.md`
- **The constitution:** `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/constitution.md`
- **A probe, run today:** `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/evidence/job-assign-probe/`, with its hooks, the settings and the logged hook inputs.
- **Old code worth reading for the mechanism:**
  - `rewrite/domains/software-development/core/main-thread/flows/flow-code-agent-dispatch/scripts/agent-prompt/prepare-agent-prompt.sh`
  - `rewrite/domains/software-development/core/main-thread/procedures/procedure-seat-run/scripts/hooks/seat-bind-hook.sh`

## What is being agreed

### The job is the only unit

- **No seats.** A job is one piece of work given to one agent: build, test, review or fix (devops later). It ends with its own submitted event and is never reused.
- **`job.dispatched`** is written by a script main runs, never by main itself. It holds everything needed to start a fresh agent:
  - kind and target;
  - the plugins, named, not copied;
  - the version of the context, grill and spec, pinned at dispatch (always the latest);
  - the payload, which varies by kind: the task and the spec path; the build to test; the commit or diff to review, the file group and prior findings; the chosen finding IDs for a fix.
- **The job is the credential.** Hooks inside the agent look up its `agent_id` to find its job, and with it the write scope, the target and what the agent may do.

### Cold and hot delivery of the same event

- **Cold:** main makes an Agent call whose whole prompt is `JOB: <event path>`.
  - The PreToolUse hook on Agent checks the event and pours in the plugins and the payload. It refuses a job agent without a valid `JOB:` line.
  - The PostToolUse hook gets the `agentId` and writes **`job.assigned`** `{job, agent}`.
- **Hot:** main reuses a live agent (its context under about 70%, and it suits the job) through SendMessage with `JOB: <event path>`.
  - A PreToolUse hook on SendMessage replaces the message with the payload only (no plugins), refuses a message to a job agent without a `JOB:` line, and writes `job.assigned` at once.
  - The dispatch script refuses a hot agent that lacks a plugin the job needs. When the agent holds an older context or spec version, the message adds the new path, or main goes cold.
  - **Not yet probed:** whether a PreToolUse hook can match SendMessage and rewrite its input.
- Plugins can be poured only by the Agent hook, and an Agent call always creates a new agent. So only a cold agent ever receives them.

### Correlation, proven by the probe

- PreToolUse and PostToolUse on one Agent call share its `tool_use_id`.
- PostToolUse sees the prompt as PreToolUse rewrote it, so it holds the `JOB:` line, and it sees `tool_response.agentId`.
- Every tool call inside the agent carries the same `agent_id` and its `agent_type`.
- So `job.assigned` is tied to `job.dispatched` by two keys that must agree: the job path and the `tool_use_id`. Two events are enough, and the old middle event (`dispatch.allowed`) goes.
- **Identity:** the agent id is the real key, since SendMessage uses it. A readable name is composed from kind, language, frameworks and a short id, such as `build-kotlin-spring-af6bac`. Every event of the job carries the job and that identity. Seqs stay internal; the human sees names and words.

### Submitting

- The agent writes a draft report and stops. Its Stop hook refuses until the report is there and valid.
- On a valid report:
  - **Build or test:** the script commits the work and writes `build.submitted` or `test.submitted`, with the commit in the body.
  - **Review:** the script writes `review.submitted`.
- A reviewer has no tree, no Bash, and Write and Edit only on its report path.

### Rounds and the harvest

- Review jobs dispatched together for one target share a **round**, which is the old `review-pass.started` with its expected set.
- **Main's Stop:** a scan script reads the events and answers two separate questions:
  1. where am I in my flows (this exists today);
  2. which event is still waiting for its next step.
- A round is complete when every dispatched review job of it has its `review.submitted`. A script then assigns finding IDs, merges and computes the verdict (`review.merged`), and main shows the totals gate.
- The human's choice is an event (`fix.chosen`). The fix job targets the build and carries the chosen IDs, usually for the hot builder. Its `build.submitted` starts the next round.
- Scans group by target, so several builds and review rounds running at once in one effort never mix.

### One table drives the offers

The scan matches each waiting event against a small table in a script, not prose:

| Event without a follow-up | Main offers |
|---|---|
| `build.submitted` | a review round |
| review round complete, target a build | the fix gate |
| `external-review.received` (from scheduled polling of our PR) | judging the comments |
| review round complete, target an external review | fix, then one reply on the PR |
| `pr.review-requested` (a foreign PR) | a review round |
| review round complete, target a foreign PR | choose and post comments |

A review job's target can be any event: a build, an external review or a foreign PR. Only the target and the last step differ between the four flows.

## What we ask

1. **Apply the model to every scenario in the two old documents.** At least:
   - internal first review and re-review;
   - hot and cold reviewers;
   - the test-plan challenge;
   - external review;
   - the foreign PR;
   - and anything else they hold.

   For each one, say whether the job model carries it, and how: which events, in what order, and who writes them.
2. **What the old documents decided that the model drops or breaks,** such as the pass's expected set, stable IDs, keys owned by the reviewer that raised them, partial reads, squads, cancel, or the challenge's place. Say whether each loss is fine or a gap.
3. **Does correlation hold?** Hot delivery through SendMessage, an agent that dies before it submits, a round where one reviewer never reports, two rounds on one target, a fix covering findings from two rounds.
4. **Does it meet the constitution?** Small pieces, events written only by scripts, no micromanaging prose, main assembling with the human.
5. **Verdict:** works, works with changes (name them), or doesn't work (say why).

Please write your answer to `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/reviews/job-model-fable.md`, send the full result to Dev Beta, and give the owner one or two lines.
