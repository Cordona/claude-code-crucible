# Next changes 1–5, as built: verdict (2026-11-23)

By Crucible Fable Reviwer, for the owner. I judged the evidence and the constitution, not the code. Nothing here is a go.

## Verdict: built as agreed, with three small corrections to the record

All five changes do what was agreed, and the evidence reproduces. Nothing needs rebuilding. Three things in the written record are wrong or missing, and one behaviour is worth a decision.

## What I did

- **Reran 17 of the 18 evidence runs** from `/` in my own scratch space. Each exits 0 and matches the stored output; the only differences are fresh keys, a timing of 10 against 11 seconds, a temp-file name, and the tracker lines I removed. I did not rerun `tracker-run.sh`, and I removed the two lines of `installed-run.sh` that read GitHub.
- **Counts match the hand-off:** dev-base 67, git-commit 89, git-mount 163, git-push 85, git-worktree 321, internals-guard 49, rollback 22. No FAIL anywhere.
- **Ran `--help` on all 82 scripts** and compared each with its folder.
- **Timed the new read hook** on ordinary calls.
- **Read the specs' known limits, the changed skill prose, and the live record of the hook.**

Nothing was left running.

## 1. events-read fails closed: done

The reader prints all events or none, exits 5 and names the file. Both additions I asked for are there:

- **Core's callers are shown refusing:** the gate's answer reader, the effort's state, status and list, the spec approval, the grill, the context's verify and cut, every flow script, the identity. None answers "nothing on record". After the repair each reads again.
- **The writer refuses on a damaged log** and says a human must look. The flow's Stop hook stays silent and lets the stop through.

**One behaviour to decide: `effort-list.sh`.** One damaged effort makes the whole list fail, so a single bad file in one old effort hides every other effort from main. Each effort is its own log, so "all or nothing" is the right rule inside an effort and too strict across efforts. I'd list the healthy ones and name the damaged one on stderr. Small, and unlikely in practice.

## 2. `scripts/main/` and `scripts/internal/`: done

- Every component has the split; no script is left loose in `scripts/`.
- All 82 helps agree with their folder: every internal one says "not for main to call", no main one does. No help is over 25 lines or wider than 80.
- Every skill's closing sentence points only at `scripts/main/`.
- Total help text is 1,681 lines, down from 1,761.

**One claim I could not check:** the hand-off says the help checker now enforces folder against help. I found no checker with that rule on disk. My own check passes today; without the checker nothing keeps it true. Please name the file in the hand-off, or say it isn't built.

## 3. One home per shared rule: done

- **`dev-base`** holds the repository rule and the time-limit runner, has no skill, and depends on nothing. Each caller refuses plainly when it isn't installed beside it.
- **The runner stops everything the command started,** shown with a signer's whole process tree. Its limit (a process that has left the tree; no `pgrep`) is in the spec.
- **Liveness is out of all seven rules.** The scripts ask `worktree-trees.sh`, and ask again just before writing; a tree dropped meanwhile gets no event.

**The known limit for liveness reads well.** It says what the rules no longer check, what would pass them, and what stops it. It is the same position as for the identity, in the same words.

## 4. Held lock, and the roll back

**The owner's decision is built and well proven.** `rollback-run.out` is the clearest evidence in the set: for move, catch-up and discard it shows the tree and the log before, the refusal with exit 6, both byte-identical after, then the rerun making the change with exactly one new event.

Every write path now has a held-lock case. Three corrections:

1. **A stale line in the spec.** The domain spec's known limits still say a move, catch-up or discard whose event write fails "has already changed the tree; the event is missing until the human looks". That is the old behaviour. It now contradicts the built one and should go.

2. **"Exit 6 always means nothing changed: rerun" is not true for three scripts.** The helps say it honestly; the hand-off's sentence doesn't. There are three kinds:
   - **Rolled back, rerun:** cut, move, catch-up, discard, mount-apply, the identity, and core's writers.
   - **Change stays, rerun records it:** push (shown), and drop ("after the removal: rerun").
   - **Change stays, never recorded:** mount-undo. The mount is out and no `mount.undone` is written, then or later. Undoing is the safe direction, so I would not roll it back. But the log then holds a mount with no undo, and the spec should say so.

3. **Drop under a held lock is not shown.** It is the one script that removes a folder and a branch and then relies on the rerun to write the event. One case: the lock held, exit 6, then the rerun writes `worktree.dropped` for a tree that is already gone.

**The `catch-up --abort` limit** is recorded in the hand-off only. The hand-off is rewritten at every stage, so the limit belongs in the spec's known limits. It is harmless: what is lost are resolutions the human had just chosen to throw away.

## 5. The read hook: done, and the subagent choice is fine

- **Denied from a project, allowed from inside the framework's repository,** shown both by fed input and by a live session. The lookalike project is never caught; links into the internals are.
- **A fault allows the call:** bad input, `jq` missing, `realpath` missing.
- **The deny reason says what to do next,** including telling the human when a script misbehaves.
- **Cost:** about 35 ms on an ordinary Read or Bash call. Not a concern.

**Skipping subagents: I agree with it for now.** I suggested covering them. But what an agent may read is a question for the agent-run design, which is next, and deciding it there is better than deciding it in this hook today. Note it in the agent-run map so it is not forgotten.

**Two limits to keep in view:**
- The Bash half grew past the "keep it simple" line: it now follows `~`, `$HOME` and `NAME=`. Each case is proven, so leave it. Add no more to it; it catches a slip, it is not a wall.
- The live record shows Read only. One live Bash denial would close it, at the next live run, not as a run of its own.

## The prose changes

- **git-commit's description** is right: it says what the skill does, when to use it, and what it never writes. It no longer names scripts main can't call.
- **The liveness known limit:** right, see item 3.
- **The skills' closing sentence** is the same everywhere and names one folder.

## Against the constitution

Holds, and better than before:
- **Events are facts (4):** a damaged log now stops everything that would have read it as empty, and a refused write leaves no change behind in every case but the three named above.
- **One home (11):** the three duplications the elevated review found are gone.
- **Token efficiency (8):** main lists one folder per skill, and the helps shrank.
- **Safe by default (10):** the hook fails open, and the human's own Crucible sessions are untouched.

## What to fix, ranked

1. Remove the stale known limit for move, catch-up and discard; add the `--abort` limit and the mount-undo case to the spec.
2. Correct the hand-off's "always": three kinds of exit 6.
3. One held-lock case for `worktree-drop.sh`.
4. Name the help checker that enforces folder against help, or record it as not built.
5. Decide `effort-list.sh` with one damaged effort.

## What this does not show

How main behaves with any of it. The folder split and the hook change what main sees; no live run has used them yet beyond the three-call hook record.
