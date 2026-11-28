# The setup merge and the snapshot reader, as built: verdict (2026-11-23)

By Crucible Fable Reviwer, for the owner. I judged the evidence, not the code. Nothing here is a go.

## Verdict: confirmed

The merge is built as agreed and no evidence was lost that matters. One small thing is left, in the record.

## What I did

- **Reran git-worktree, git-commit and git-mount** against a frozen copy of the tree. All exit 0 and match the stored counts: 302, 103 and 165 PASS, no FAIL.
- **Mapped the setup cases myself,** from the checks in my rerun before the merge (332) and after (302), without the builder's report.
- **Ran the help checker** on every script: no problem.
- **Read the spec and the hand-off** for the merge and the snapshot reader.

Nothing was left running.

## The merge

One script, `worktree-setup.sh`, where there were four. The three `setup-*.sh` files are gone.

**The drop from 332 to 302 checks is explained, and it is the right kind of drop.** 48 checks went and 18 came. Those that went are of three kinds:

- **Checks of the hand-off itself:** a plan that is not JSON, a plan naming an absolute path, a plan whose tree is its checkout, `--plan`, `--folder` and `--subfolder` with bad values. With no hand-off there is nothing to check. This is the saving the merge was for.
- **The three scripts' own help and coverage lines.**
- **Behaviour, now shown through the one script.** I found each of these again:
  - node and python detected; dependency folders copied; a tracked one left;
  - a git-ignored `.env` copied, an unignored `auth.json` left out;
  - `.worktreeinclude` entries reaching the copy;
  - a second run overwriting nothing;
  - a launcher repointed, a binary left alone, a missing launcher folder skipped;
  - the problems: names with a control character, a folder leading outside, a failed copy, a failed folder creation, a read-only launcher, a launcher folder that is a link leading outside;
  - the refusals: a linked worktree, a path that is not absolute, the same folder twice, a missing tool.

**The read-only plan survives as an order.** The new case "the plan refuses before any copy: no line on stdout, nothing in the tree" shows it.

**One case is gone on purpose:** the repoint leaving alone "a launcher that is the source file itself". That state could only arise when a caller handed the old repoint script some other tree. The merged script repoints only what it has just copied, so it can't be reached, and the check "the checkout's own launcher unchanged" is in my rerun. Closed.

## The UTF-8 limit

The old limit (a dependency folder with such a name can't be planned) is gone from the spec. What remains is narrower and honest: a line in `.worktreeinclude` that spells such a path out matches nothing. I did not rerun the Linux container proof; I take it as reported.

## The snapshot reader

- `commit-snapshots.sh` is in git-commit, internal, with a help that states its one job.
- No domain script holds the snapshot subject as text any more.
- The spec names it as the one home, and `effort-commits.sh` as its caller.
- git-commit's and git-mount's evidence both pass with it.

## The tracker comment

Reworded: it now says what the check protects, not what it copies.

## What is left

1. **Two stale lines in the hand-off** still list "fat files still to split: mount-apply, setup-plan, the git-worktree lib, tracker-read" (in "Overnight help trim" and in "Where things stand"). The split evaluation answered that: nothing is split. Mark them as closed so the next reader doesn't pick them up as work.
