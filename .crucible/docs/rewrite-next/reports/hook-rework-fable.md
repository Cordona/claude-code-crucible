# The hook rework, form A: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** the hook folders as they now are, the three `matchers.json` files that changed, and in full `job-agent-tools.sh`, `guard-framework.sh`, `refuse-cd-git.sh` and the body of `deny-background-bash.sh`.

**Not done:** I ran nothing; the runner counts are Dev Beta's. I did not reread the eight moved stop-hook steps or `write-scope.sh`, so I take the path changes on the runners' word.

## Verdict

**Approved as built. All four deviations are fine.** The rework follows the form the owner chose and the four notes I gave on the contract. Two questions are still open from the trial 2 review, and I'd watch one thing in the matrix rerun.

| # | Deviation | My view |
|---|---|---|
| 1 | The wording of the `; echo $?` reason | **Fine.** It says what to drop, why, and that Bash still works |
| 2 | The Bash steps trust the wrapper's type check | **Fine,** since a step can't be registered alone |
| 3 | The stop hook's steps keep their arguments | **Right.** That is what I asked for |
| 4 | A folder with spaces is named up to its first space | **Fine.** The agent still gets the point |

## 1. What I checked

- **The wrapper never decides by itself.** It prints deny when a step denied, allow only when a step allowed, a rewritten command with either an allow or no decision, and otherwise nothing. A step that fails gives no answer and the others still run.
- **The first deny stops the rest,** and each step sees the command as the step before left it.
- **One `case` on the tool** picks the steps, so a Bash call never starts the write-scope step.
- **The order of the Bash steps** is right: the background refusal, then the `cd` refusal, then the time limit, so a command that will be refused isn't rewritten first.
- **The event log's wrapper** prints the first deny and nothing else, with no shared engine.
- **The `cd` refusal keeps to the three limits:** only a chain that holds both a `cd` and a git command, only the two forms the trials met, and no job lookup. A `cd` followed by a project's own check passes.

## 2. On deviation 2

Run alone, `deny-background-bash.sh` refuses any background command, main's included. That would be a fault only if the step were registered as a hook by itself, and the install check now refuses that. Its help says it is for a job agent's call. So the rule "runnable alone" holds for what it is meant for: proving each step with its own cases.

## 3. Still open from the trial 2 review

Dev Beta's message doesn't say how the probe came out. Before the trials rerun I'd want both answers written down:

1. **Can a sub-agent start in its tree?** The `cd` refusal was built, so I take the answer to be no. Please confirm.
2. **With an allow rule for a project's check command, does `cd <tree> && <that command>` run for a background agent?** The new step lets that chain through. Whether Claude Code then runs it decides if a job agent can run the checks of a project that must be run from its own folder.

## 4. One thing to watch in the matrix rerun

A job agent's Bash call now passes through two wrappers and five steps, each a shell and one or more `jq` calls. That is a dozen or more small processes before every command. It is probably a few tenths of a second, which is fine. The matrix's saved hook calls carry start times, so the rerun can state the number instead of my guess. If it is over a second, the first thing to merge is the three Bash steps' input parsing.
