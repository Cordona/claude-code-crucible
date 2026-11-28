# The build kind's layout: Fable's alignment (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `reports/jobs-build-kind-brief.md`. In `new-rewrite/`: `write-scope.sh`, how `event-write.sh` finds a rule, the builder's two `submissions/` files.

**Not done:** nothing was run. I did not read the installer, so what I say about installed names is from `event-write.sh` alone.

## Verdict

**Aligned on the layout and the split. Four corrections before it is built,** none of them large:

1. Name the kind's folder `job-build`, not `build`.
2. `job.json` lacks the agent a build runs on, and which refs are required.
3. The hook should get the write scope from a jobs script, not from a path into `jobs/`.
4. No `SKILL.md` for the kind in this step, and not one that says "when".

## 1. Layout and the split: aligned

**Job facts in the job's folder, submission facts with the agent: right.** What a job may write is true from the moment it starts; what the agent hands in is true at the end. They were in one file only because there was one file.

**One correction, the name.** `event-write.sh` looks for rules one level down (`<components>/*/events/`), so the pieces sit flat once installed. A component called `build` is then a bare word beside `git-push` and `code-builder`, and later ones would be `test` and `review`. Call them `job-build`, `job-test`, `job-review`: the name says what it is, and nothing collides.

**State what this step does not do.** After it, `job.defined` is written and nothing consumes it: the door, assign and the submission rules still key on `job.dispatched`. That is fine for step 1 of 6. Say it in the spec, so nobody reads the step as a working build.

## 2. `job.json`: two things missing, one to decide

**Missing: the agent.** The shapes dropped `agent_type` because "the kind decides the base". Then the kind has to say it: `"agent": "code-builder"`. The door needs it in the next step, and resolve can already use it to refuse a kind whose agent isn't installed.

**Missing: required or optional.** A build with no spec, or with no grills, is a normal small effort. A build with no context is not. As drafted, the file can't say that. It also can't say that `grills` is a list and the others are one. This is a JSON shape, so the form is the owner's; the smallest I see is a `required` list beside the map, and resolve accepting one seq or a list for any ref.

**To decide, not in this step: how the one rule learns a kind's facts.** A rule is pure jq on the event and the earlier events. It can't read `job.json` by the kind's name. So "opens an iteration" either stays as `kind == "build"` in the rule, or the rule imports each kind's file by name (one line per kind), or resolve writes the fact into the event. Keeping `kind == "build"` for this step is fine. Settle it before the second kind moves, because that is when a kind's name in shared code starts to cost.

**The rest is right:** `tree: ["cut", "use"]`, and `write_scope` with the two words the hook already knows.

## 3. The hook reading from `jobs/`

**The coupling is acceptable; it already exists.** `write-scope.sh` calls `agent-jobs/scripts/internal/agent-job.sh` today to find the agent's open job. An agent-side hook asking the jobs side "what is this agent's job" is the design.

**But ask, don't reach in.** Have the script that returns the job also return its write scope. Then the hook knows one script and no file layout, and the fallback (section 4) lives in that one script instead of in the hook.

**Not in the event.** Putting the scope in `job.defined` changes an approved shape to repeat, in every job, a fact that is the kind's.

## 4. The fallback: fine, with one rule

**Fine.** Moving all ten at once would create nine job folders holding one word each, for kinds not designed yet.

**The rule:** a kind never has the word in both places. `build.json` loses `writes` in the same change that `job-build/job.json` gains `write_scope`. Then there is never a question of which one wins. And keep today's behaviour for a missing word: no decision, the human is told.

## 5. `SKILL.md` per kind: not in this step

**Folder first.** Build `job.json` only. Main learns that kinds exist, and what a build needs, from the shared piece: the prose of `job-define` (how to propose jobs) and resolve's own output ("a build needs context; spec and grills if there are any"). That is one skill in main's list, not one per kind.

**Add a kind's prose when a run shows main lacking it.** The first live run of a build through this chain is the test.

**If it is written anyway, not "when main proposes a build".** When is the adaptive flow's and the human's. A kind's prose says what the job is for, what it needs and what comes back.

## 6. Validation to add

Step 1's cases from my earlier review still apply (the stale case, a rejected gate). For this layout, two more:
- a build proposed with no spec and no grills resolves; one with no context is refused with the line that says what is needed;
- a builder's write outside its tree is still denied after `writes` moves, and a kind not yet moved is still scoped from `submissions/`.

## 7. For the owner

1. The folder names: `job-build` and so on (my lean), or bare `build`.
2. The form of required and optional refs in `job.json`, and `agent` in it.
3. No per-kind `SKILL.md` until a run shows the need (my lean), or one from the start.
