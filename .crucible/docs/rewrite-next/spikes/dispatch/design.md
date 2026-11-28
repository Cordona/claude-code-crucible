# Spike: dispatching a job agent (design, for Fable)

2026-11-26. Concept validation only; the code is spike-grade, thrown away after. The owner asked for hard facts before any spec.

## What we want to prove

One way to start a job agent that is simple and works the same for every agent: builder, tester, reviewer, and future ones (devops, doc writer) without dispatch code changes.

## The mechanism under test

1. **Main dispatches.** It runs a small dispatch script with its judgement only: the agent, the kind, hot or cold, and the choices the human made (plugins, which grills). The script checks the job with the agent's own job check, from the agent's folder, and writes `job.dispatched`. Out: the job's number.
2. **Main starts the agent** with the Agent tool, its prompt just `Job <N>`.
3. **A PreToolUse hook on Agent** (main's tool call) binds the call to that job and replaces the prompt (`updatedInput`) with one built by script from the job and the effort's events: plugins, the latest context cut, the named grills, the latest approved spec, the tree. Main's prose never reaches the agent.
4. **Guard:** an Agent call to a job-taking agent type whose prompt names no dispatched, unassigned job of that type is denied with a reason naming the dispatch script. Other agent types (Explore, general-purpose) pass untouched.
5. **Hot:** a resume through SendMessage passes the same hook: bound to a new job for that agent, or denied.

## Scripts (SRP, no god script)

Each is callable alone; the hook is a thin wrapper over steps.

- `job-check.sh`: finds the agent's own job check in its folder and runs it on a draft job; prints repair lines, exits non-zero on a refusal.
- `job-write.sh`: writes `job.dispatched` for a checked draft; prints the job number.
- `job-dispatch.sh`: the door main runs; calls `job-check.sh`, then `job-write.sh`. Holds no rule of its own.
- `job-prompt.sh`: prints the prompt for a job, from its event and the effort's events.
- Hook `pre-tool-use/dispatch-guard.sh` (matcher Agent, SendMessage) with steps:
  - `resolve-job`: one decision: which job this call is for (dispatched, unassigned, this agent type), or deny. Writes nothing, so a call refused afterwards leaves nothing to clean up;
  - `swap-prompt`: replaces the prompt with `job-prompt.sh`'s output.

An agent is job-taking because it has a job check; that one file answers both "does it take jobs" and "how is its job checked". No list in the dispatch code.

## The assignment (the concept this spike decides)

Before the Agent call the agent has no id; every built hook finds a job by the agent's id through `job.assigned`. The final verification used a lab stand-in for that event. This spike finds the first moment the id exists (the agent's start, or the end of the Agent call), writes `job.assigned` once there, and records whether that moment comes before the agent's first tool call (if so, the write guard's first-write window closes). In S1 the stand-in hands in through the real stop hook, with no lab assignment.

## Spikes

| # | Question | Run | Pass |
|---|---|---|---|
| S1 | Does `updatedInput` on Agent replace the prompt on Claude Code 2.1.332? | Opus main dispatches a stand-in; the stand-in writes the prompt it received to a file | The received prompt equals `job-prompt.sh`'s output byte for byte |
| S2 | Is a bypass stopped, and does main recover alone? | Main is asked to start a job agent with its own prose | Denied with the reason; main then dispatches and starts it, unsteered |
| S3 | Does main repair a bad job from the repair lines alone? | Main is asked for a job with a missing or wrong field | Refused, then fixed and written, no message from me |
| S4 | Agent-agnostic? | A made-up `doc-writer` that is only a folder (definition, job check, kind) | Dispatched and prompted like the builder; zero dispatch code changes (diff empty); shows how the type name leads to the folder in the installed layout, through the links |
| S5 | Parallel and hot | 3 Agent calls in one message on 3 jobs; then a SendMessage resume | Each call bound to its own job; SendMessage hooked, bound or denied; record whether the 3 hooks run in turn or together |
| S6 | Two calls naming the same job | Main starts two agents on job N | Record it; expected: the second ends with no job and the human is told |
| S7 | SendMessage to a non-job target | Another session, a helper agent | Passes untouched |
| S8 | SendMessage to an agent whose job is open | Main speaks mid-job | Record only what the hook sees (whether main may is the owner's call) |
| S9 | Start folder | Record the Agent call's full input | Does any field set the start folder (36 refusals came from `cd <tree> && …`) |
| S10 | Real-size prompt | S1 again with plugins, context cut and spec | Same pass as S1 |

Each spike also records: the hook's payload for Agent and SendMessage, and the deny text main saw.

## How it runs

- Sandbox outside the owner's home, no global git config, `gpgsign=false`, stub `gh`/`glab`, kill by PID only, waits of 2 minutes or less.
- Main is Opus (its behaviour is what's tested), headless, plus one interactive check of S2, recording which prompt the human sees at a permission prompt. Sub-agents are cheap stand-ins.
- Raw outputs saved per spike; one results page.

## Out of scope

What each kind's job carries (the spec after), the review merge, the dispatch and test-plan gates, landing.

## Fable

Reviewed: `reports/dispatch-spike-design-fable.md`; corrections applied above.

## Questions asked

1. Is binding by `Job <N>` in the prompt plus a prompt swap the simplest sound shape, or is there a simpler one to spike too?
2. Is the script split right (SRP, DRY), and is "job-taking is a fact of the agent's folder" the right seam?
3. Anything missing from S1–S5 that would leave a concept unproven?
