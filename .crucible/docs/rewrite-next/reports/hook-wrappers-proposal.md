# Hooks: one settings entry per hook, a thin wrapper, independent single-purpose steps

By Dev Beta, from the owner's idea, for Fable's review.

## The owner's rule

- In `settings.json`, a hook is **one entry pointing at one wrapper**, never one entry per check. If the framework depends on 5 hooks, settings hold 5 entries, not 50.
- The wrapper is the hook's single entry point. It calls separate scripts, each doing one thing well (SRP), and **each runnable on its own**.
- The wrapper sits at the hook's level, for example `agent-submission/hooks/subagent-stop/`. The scripts it calls sit in a folder beneath it, so it's plain which is the wrapper and which are its internals.

## Today: 18 hook scripts, each a settings entry

| Component | Event | Scripts |
|---|---|---|
| agent-submission | SubagentStop | `submit-agent-work.sh`, already a wrapper. Its 8 steps sit **beside** it, not beneath it. |
| agent-submission | PreToolUse | `job-agent-bash.sh` (two concerns in one: background deny and the timeout; a cd+git refusal would be a third); `job-agent-writes.sh` (one concern) |
| agent-jobs | Stop | `end-gone-jobs.sh` |
| crucible-adaptive-flow | Stop | `remind-flow-position.sh` |
| crucible-events | PreToolUse | `deny-direct-event-write.sh`, `deny-internals-read.sh` |
| crucible-gate | PostToolUse | `record-gate-answer.sh` |
| crucible-gate | PreToolUse | `hold-question-until-card-shown.sh` |
| crucible-gate | Stop | `require-card-shown.sh` |

The installer registers each top-level script as its own entry, with its matcher from the component's `matchers.json`. So main's Stop alone has three entries, one from each of three components.

## The proposal

**Within a component:** one wrapper per hook event, at `hooks/<event>/<wrapper>.sh`. Its steps go in `hooks/<event>/steps/`, one script each, each with `--help` and runnable alone with the hook's JSON on stdin.

The name proposed for the folder is **`steps/`**: the wrapper runs them in order, and each one is a step.

The wrapper:
- reads the hook input once;
- runs the steps in a fixed order;
- combines their answers:
  - the first `deny` or `block` wins and stops the rest;
  - each step's `updatedInput` feeds the next;
  - `systemMessage` texts are joined;
- prints one answer.

**Across components, the open design question:** settings still hold one entry per component per event, for example three for main's Stop. The owner's "5 hooks, 5 entries" needs one entry per event for the whole install. There are two ways:
- **(A)** Keep one entry per component per event. Components stay independent, and the count is components × events (about 9 today).
- **(B)** One framework-level runner per hook event: `framework/core/.../hook-run.sh <event>`, registered once per event, so about 5 entries. It finds each installed component's wrapper for that event, applies the component's matcher itself, and combines the answers by the same rule.
  - **Pros:** it needs no component to know another, and it makes the order across components explicit (it fixes Claude Code's parallel run and its clashing `updatedInput`).
  - **Cost:** a runner that every hook passes through, so a fault there touches all hooks. Like today's faults, it must let the call through and tell the human.

My lean is **B**, because it gives the owner's count exactly and turns parallel runs into a defined order. But it's the kind of central piece the constitution warns about, so it needs your judgment.

## What changes, if approved

- agent-submission SubagentStop: move the 8 steps into `steps/`, a path change only.
- agent-submission PreToolUse: one wrapper (`job-agent-tools.sh`) with the steps `deny-background-bash.sh`, `add-bash-timeout.sh` and `refuse-cd-git.sh` (if P19 needs it), plus `write-scope.sh`, since Write, Edit and Bash share one PreToolUse event. The matcher then becomes the union, and each step checks its own tool.
- Every other component's single-purpose hook becomes `hooks/<event>/<wrapper>.sh` with one step in `steps/`, or stays a lone script, if you think a one-step wrapper is ceremony.
- Under B, the installer registers only the runner per event.
- Proofs: every runner green, plus cases for the combine rule (deny wins, input chaining, message joining) and for each step run alone.

## Asked of Fable

1. Is `steps/` the right name, and the wrapper and step contract?
2. A or B?
3. A one-step hook: wrapper and `steps/`, or a lone script?
