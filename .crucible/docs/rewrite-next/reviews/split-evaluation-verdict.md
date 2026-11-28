# Split evaluation: verdict (2026-11-23)

By Crucible Fable Reviwer, for the owner, on `split-evaluation-result.md`. I judged it against the owner's test and the constitution. I read the scripts' helps, their callers and the spec; I did not read the evaluators' full reports, which are in Dev Beta's scratchpad. Nothing here is a go.

## In short

**I agree with the result: split nothing, merge the setup chain back.** On the open call: **merge `setup-plan.sh` too.** Of the three "rule in two places" notes, **one is real** (the snapshot subject); the other two are not duplicated rules and should be left alone.

This also corrects me. In the elevated review I ranked four files for splitting. By the owner's test, none of them should be split.

## The setup-plan call: merge it

Measured against the test, line by line:

- **Would a caller run it on its own?** No. It has one caller, `worktree-setup.sh`, and nothing else can use its output. Main never sees a plan: the cut is one step, with no card that shows what will be copied.
- **Does the split pass internal state between files?** Yes, and this is the strongest evidence. The plan is handed over as JSON, and the spec carries a known limit that exists only because of that hand-off: a dependency folder whose name is not valid UTF-8 can't be named in the plan. That is the test's own phrase, "a private protocol with new ways to fail", already written down as a limit.
- **Does it change for a different reason?** This is the argument for keeping it: adding a technology. But that reason lives in the data file, `lib/worktree-setup.json`, and its jq rules. Those stay where they are after a merge. Adding a technology will still touch only the data.
- **"A read-only plan" is worth keeping as an order, not as a file.** Inside the merged script the plan is still made whole before anything is copied. That is the property; the file boundary adds nothing to it.

So all three reasons to merge apply, and the one reason to keep is met without the split. If a caller for a plan alone ever appears (main showing the human what a cut would copy), it can be cut out again then, with a real contract to cut it to.

**One condition on the merge: no evidence case is lost.** Today the evidence drives plan, copy and repoint one by one, which makes cases such as "tracked", "unignored secret", "bad name", "exists" and "flag symlink" easy to stage. After the merge each must be shown through `worktree-setup.sh` with real folders. I'd ask for a list of the setup cases before and after, one to one, with the merge.

**`worktree-setup.sh` stays apart from `worktree-cut.sh`: agreed.** It also has one caller, so it deserves the question. The difference is the hand-off: two folder paths in, lines out, nothing private. And it changes for its own reason (what a tree needs) while the cut changes with git.

## The three "rule in two places" notes

**1. The snapshot commit's subject: real. Give it one home.**
- git-mount recognises a snapshot by matching a subject text that git-commit composes. Two components, one string.
- If the text ever changes in git-commit, nothing fails loudly: git-mount just stops seeing snapshots, and a mount starts from the wrong commit or refuses for a reason that isn't the reason.
- The home is git-commit, which owns commit messages. It should answer "is this commit a snapshot"; git-mount should ask. That is the same move as the gate's reader this morning.

**2. The mount record's shape: not a duplicated rule. Leave it.**
- It is one private file inside one component, with a writer and a reader. Any file format has two ends.
- If they drift, every mount evidence case fails at once, because each one writes the record and reads it back.
- Giving it "one home" means either a second mode on `mount-record.sh` or another script: more surface to remove a risk that can't stay hidden.

**3. The safe-link pattern in `tracker-read.sh`: not a shared rule. Leave it, and fix one comment.**
- The tracker script checks the URL to protect its own command line before it calls a tool. Core checks links again when the issue is added to the context.
- So this is a script validating its own input, which is what we want from every script. If the two ever differ, core's check still refuses, loudly.
- Sharing it would mean core offering a new script for one domain caller.
- The one thing that will go stale is the comment claiming it is "the same characters core's context accepts". Say what the check is for instead.

So Dev Beta's proposal 2 becomes: one of the three, not all three.

## The rest of the result

- **Split nothing: agreed.** No file is a hub by the test.
- **`worktree-catch-up.sh` with `--with` and `--abort`: keep.** One event, shared helpers. Agreed with the condition both evaluators gave.
- **`mount-apply.sh`: keep. I withdraw my ranking.** I argued the checks were a job of their own because main might need their result for a card. No caller runs them alone, and no live run has used the toolbelt, so that need was my guess. If a live run shows main wanting to know whether a mount can apply before asking the human, that is the moment to look again.
- **`lib/git-worktree.sh`, `tracker-read.sh`: keep.** My ranking was by size and a second job I could name, not by who calls what. The owner's test is the better one.
- **The five git libraries repeating the same basics: leave them, as proposed.** A shared library would make each skill load another skill's code, and components here call each other's scripts, they don't share code. If one of those basics ever turns out to be a rule that must not differ, it becomes a script in `dev-base`, as the repository rule did. One note: the result cites the constitution for "components never source across components". The constitution doesn't say that in those words; it is our working practice, and the spec is where it should be written if it isn't.
- **`check-question-shape.sh` as a jq lib: no.** It has its own contract and its own evidence. Changing its form gains nothing.
- **`effort-commits.sh`: keep.** If item 1 above is done, its hard-coded subject goes, which is its only wart.

## What I would do, ranked

1. Merge `setup-plan.sh`, `setup-copy.sh` and `setup-repoint.sh` into `worktree-setup.sh`, with the setup evidence cases mapped one to one. The UTF-8 known limit should disappear with the plan JSON; if it does, remove it from the spec.
2. git-commit answers "is this commit a snapshot"; git-mount asks.
3. Reword the safe-link comment in `tracker-read.sh`.
4. Keep everything else.

## A caution on confidence

Two blind evaluators agreeing is good evidence, and I reach the same result from the helps and callers. But all three of us judged with no live use of the toolbelt behind us. The merge is safe on that footing because it removes hand-offs and adds no contract. I would not make any further structural change to the toolbelt before a live run has used it.
