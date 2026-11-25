# The builder and tester slices as built: Fable's design review (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `agent-slices-design-brief.md`. Talking only; the owner's go is the only go.

**What I read:** every event rule and jq lib in `agent-jobs`, the stop hook's wrapper, `report-check.sh`, the agents' validation scripts, `tester-check.sh`, `tester-facts.sh`, `test-report.jq`, `fix-report.jq`, the top of `build-report.jq`, and the diffs of the event writer and the install check.

**Not done:** I didn't rerun either proof, and I didn't read `test-plan.jq`, the hook's other steps or the git-commit diffs. Design only, as asked.

## Verdict

**The three-part shape is right and it held when the second agent arrived.** The stop hook still names no agent, the tester reuses the builder's report rules without copying them, and the rules stay plain jq over one joined input.

**One part did not hold: `job.dispatched`.** More than half of that rule is now the tester's, and it decides how a dispatch is gated before the dispatch has been talked through. That is the one thing I'd change before a third agent is added.

| # | Finding | Weight |
|---|---|---|
| 1 | The job's start rule knows every agent's kinds, and the tester's plan and approval rules | **high** |
| 2 | `fix.submitted`'s rule sits in the builder, though both agents write it | medium |
| 3 | The per-kind validation scripts hold two names each and nothing else | medium |
| 4 | The framework core's install check knows the agents' file convention | medium |
| 5 | The shared report rules are still named after the build | low |
| 6 | Two stand-ins used as keys: "names no plan", and the agent type as the fix loop | low |

## 1. `job.dispatched` knows too much (the brief's item 4)

**What is there now:**
- the list of all job kinds, and which fields each kind may carry;
- the tester's rules: a test job must name the newest plan on its tree, and that plan must be approved by a gate answer with the record `test-plan`;
- the shape of a challenge.

**Why it matters:**
- **A new agent is no longer added by adding its folder.** A reviewer means editing `agent-jobs` again. The submission side avoided exactly this.
- **It builds part of the dispatch.** The owner's standing word is that the dispatch needs a long talk first. Which jobs need an approval, and what counts as one, is that talk. The rule also fixes the names of two scripts that don't exist yet, as the only allowed writers.

**What I'd do:**
- **`agent-jobs` keeps what is true of every job:** an agent type, a tree, a report path, the iteration, the setup, known failures. Knowing that a build opens an iteration and a fix has a round is fine; that is the job model itself.
- **What only one kind carries goes to that agent's component,** as the report check already does.
- **How it is checked is the first question of the dispatch talk.** A jq include can't be chosen at run time, so a rule can't load "the agent's own" part by name. The mirror of the submission side would be a check per kind in the agent's component (`<kind>-job-validation.sh`), run by the dispatch before it writes. Then the dispatch knows no agent, as the hook does.
- **Until that talk:** I'd take the plan-approval rule out of the event rule and keep only the field shapes the tester's check reads. The proof writes its jobs from a fixture, so nothing in the proof needs the gate to be enforced there.

## 2. Where `fix.submitted`'s rule lives (item 3)

**Move it to `agent-submission`.** A fix is a job kind any agent may do, and `agent-submission` writes the event. Today a tester installed without the builder would have no rule for its own event, and nothing says so.

**The other four rules can stay with their agents,** as the owner asked. Each is one line that names its kind.

## 3. The per-kind validation scripts

**Six scripts, each about thirty lines, each holding two names:** the rules module and its def. The tester adds a seventh, `tester-check.sh`, to pass the facts. One check now runs through three or four scripts.

**Those names are data.** The kind's `<kind>-submission.json` could hold them beside the event and the commit flag, with the facts script when there is one. The hook's check step would then call `report-check.sh` itself.

- The owner's rule of one file per kind is kept: the JSON file is that file.
- Seven scripts go, and the pairing check in the install check goes with them (finding 4).
- It reverses a choice the owner made and I approved, so it is the owner's call. Seeing them built, the scripts add nothing the file can't say.

## 4. The framework core knows an agents' convention

`install-check.sh` in the core now checks that each agent's `<kind>-submission.json` has its validation script. That pairing is this domain's convention, written into the core. With finding 3 it disappears. Without it, the check belongs to `agent-submission`, which owns the convention.

The other two core changes are general and right: scanning `agents/` folders, and giving every event rule the components folder as its search path.

## 5. Smaller

- **`build-report.jq` in `agent-submission`** is now two things: the rules every work report shares, and the build report itself. `code-builder` holds no rules of its own. That is fine as a design, since the build report is the base the others extend. Name it for what it is, so a reader doesn't take the tester to depend on the builder.
- **`tester-facts.sh` tells the build's fixes from the tester's by "names no plan".** The spec lets a tester's fix leave the plan out. The job's agent type says it directly.
- **The fix round is counted per agent type** (item 6). It works as a stand-in, and the comment should say it is one. A loop's identity is the human's fix choice, which has no event yet.
- **The kind and its event are paired in two places:** the submission file, and the rule's one line. Small, and finding 3 doesn't remove it.

## 6. The builder's other choices

| Item | My view |
|---|---|
| 1. The shared check is a script called by path | **Right.** It is how components already call each other, and it keeps one place that prunes, reads the tree and runs the rules. |
| 2. The shared rules take parameters | **Right.** It is what lets the tester reuse them without a copy. |
| 5. A job finishes at any event that pins its report | **Right.** No list of types to keep, and the view uses the same test. |
| 7. Facts gathered by a script, passed to the rules | **Right.** The rules stay testable from fixtures, and reading events and git stays in one script. |

## 7. Against the constitution

**Nothing in the submission side.** Code refuses and never steers, the events are facts, the report is the one home, and the pieces know little of each other.

**Finding 1 is the one breach:** a piece that predicts the flow (which job needs which approval), built before the human and main have negotiated it. The rest are tidiness.

## 8. Order I'd take

1. Finding 1: slim the job's start rule now; settle the per-kind check in the dispatch talk.
2. Finding 2: move the one rule.
3. The owner's word on finding 3, which settles finding 4.
4. The small ones, with the next change to those files.
