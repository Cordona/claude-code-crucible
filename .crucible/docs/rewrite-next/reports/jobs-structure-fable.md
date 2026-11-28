# The jobs structure: Fable's review (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `specs/jobs-structure.md`. From earlier today: step 1 as built, `agent-jobs`' rules and modules, how `event-write.sh` finds a rule.

**Not done:** nothing was run. I did not read the installer or the plugin folders.

## Verdict

**Approve the structure.** Three job pieces, each one thing, with dependencies running one way (assign reads define; track reads both; nothing reads back). The agent's start outside the jobs is the right cut. The order is the one I asked for.

**Four things to settle before it is built, and one correction to the open question.**

| Point | Where |
|---|---|
| How `agent-init` finds the effort to write into | 1 |
| Plugin skill names against what the owner already has installed | 2 |
| What the tree hook does for a start that is no job's | 3 |
| Step 2 can't add `job.assigned`'s rule as a new file | 4 |
| The seven other kinds: Beta's lean, said honestly | 5 |

## 1. `agent-init`: where does its event go?

**"The agent coming to life is not a job" is right.** An agent is initialized once and may take several jobs; its file, its name and its plugins are its own.

**But its event is written into an effort's log, and a starting agent has no effort of its own.** The effort comes from the job it was started for. So `agent-initialized.sh` has to learn the effort from somewhere, and the spec doesn't say where. If the answer is "from the note the door left", then `agent-init` reads `jobs-assign`'s private note and the two pieces are not separate after all.

Say which it is:
- `agent-init` finds the effort without the jobs (the session's effort, if core has such a lookup). Then the cut is clean.
- It can only come from the job. Then one hook writing both events, as the spikes ran it, was the honest shape, and the split is in folders only.

**Two hooks on one start: fine,** with one consequence to write down: the two events can land in either order, so no rule and no audit may require `agent.initialized` before `job.assigned`. The runs so far had one hook and a fixed order.

**Who runs `agent-files.sh` at the card?** If main must remember it, that is a slip a script can cover: the card script's output names it as the next thing needed, and the door stays the net ("file missing: exists from the next turn").

## 2. The plugins as skills: one real collision

**One skill per part is forced by the evidence** (`skills:` preloads a `SKILL.md` only), and the folder shape is clean.

**The names will collide at user level.** The owner's own configuration already holds skills called `standard-security`, `standard-clean-code`, `standard-testing`, `standard-kotlin` and more, from the earlier harness. An installer that links plugins "by their `name:`" into the same place either overwrites those or is refused by them. Validation in a scratch configuration won't show it; the first real install will.

So before the plugin step: the installer refuses to replace a skill it didn't link, and the owner decides what happens to the old ones (a prefix for the new, or the old retired). This is a decision, not a detail: it touches what the owner's other sessions load.

**Main's list.** Every part is now an entry main sees. Keep each description to one line that says whose it is ("loaded for review jobs on Kotlin"), so main has no reason to load one itself.

## 3. The two installer changes

**Generic and small: agreed.**

**One question on `worktree-create`.** Installed at user level, the hook is asked about every tree start in every session, not only a job's. The owner's other sessions use tree isolation too. Say what `job-tree.sh` does for a start that is no job's: it must step aside and let Claude Code make its usual tree. If a tree hook can't step aside, that is a finding for the owner before this is installed anywhere real.

## 4. The order: right, with one fix

**Step 2 is "new files only", but `job.assigned.jq` is not a new file.** The engine allows one rule per event type. While `agent-jobs` holds `job.assigned`, `jobs-assign` can't hold another. So in step 2 `assign` is built without its rule (or tested in a sandbox where `agent-jobs` is left out, as the kits did), and the rule moves and takes its new shape in step 3. Say so, or step 2 breaks every write of `job.assigned`.

**Steps 3 and 4 kept apart:** as asked. Good.

## 5. The seven other kinds

**Beta's lean is the smaller evil, but it is not "two job models, shrinking".** As far as I can see, the two can't work on one tree:
- the old rule counts builds from `job.dispatched`, by the tree's path; the new one from `job.defined`, by the tree's event;
- so a fix dispatched the old way onto a build defined the new way is refused: "a fix needs a build first".

What stays is therefore a frozen fixture: it keeps the agent side's regression runs for the seven kinds alive, and it can't follow a new-chain build. That is acceptable, and all ten now would put six payload shapes in front of the owner at once, before the loop that most of them belong to is specified.

**Three conditions:**
1. **The spec stops saying they are gone.** `job.dispatched.jq` and `iteration.jq` leave with the last kind, not now. Today the tree shows both deleted and the open question keeps one.
2. **The job view reads either, and says which.** Its second branch is deleted with the last kind. No script but the view knows there are two.
3. **An order for the seven.** The three fix-loop kinds (build-fix, test-fix, re-review) move with the loop's step; the plan kinds and the two outside reviews each with theirs. Without an order, "for a while" has no end.

**What the owner should know:** until the loop's step lands, a build made through the new chain can be tested and reviewed but not fixed through the framework. The live run of step 5 ends at the review.

## 6. Smaller points

- **`assign/SKILL.md`** comes to me before it runs. The door's printed lines should be most of it.
- **Agent files are written once and never removed.** Fine for now; note it as a follow-up, not a mechanism.
- **Naming:** `job-assign.sh` prints a call and writes nothing; the hooks write `job.assigned`. Its `--help` should say that in its first line, or main will expect an event from it.

## 7. For the owner

1. **Plugin names against your installed skills** (section 2): prefix the new, or retire the old.
2. **The seven kinds** (section 5): the old event kept as a fixture until each moves (my lean, with the three conditions), or all ten now.
3. **`agent-init`'s effort** (section 1), once Dev Beta says which of the two it is.
