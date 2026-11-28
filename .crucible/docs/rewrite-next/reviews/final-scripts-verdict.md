# Every script, against the two rules: verdict (2026-11-23)

By Crucible Fable Reviwer, for the owner. I did this directly, on the still tree. Nothing here is a go.

## Verdict: both rules hold. One small thing to tidy.

1. **Split / don't split: followed everywhere.** No hub is left, and no unnatural split is left.
2. **Folders: followed everywhere.** Every script main calls is in `scripts/main/`. Every script run only by scripts or hooks is in `scripts/internal/`.

The one thing to tidy: six main helps still name an internal script, which main can neither run nor read.

## What I did

- **Listed every script:** 55 in `scripts/main/`, 25 in `scripts/internal/`, 6 hooks, 2 install scripts. None sits loose, and no library is run as a script.
- **Mapped the callers of each one** across all scripts, hooks, event rules, skills, step files and `CLAUDE.md`, with help text and comments set apart from real calls.
- **Read the help of every main script that another script also calls,** to see whether main has a use of its own for it.
- **Read the usage of every script with more than one form,** to look for hubs.
- **Ran the help checker** on all 80: no problem.

Not done this time: I did not rerun the 18 evidence runs. The question was placement and shape, and I reran the three runs the last change touched an hour ago.

## Rule 1: split / don't split

**No hub.** Six scripts have two usage forms. Each is one operation with a variant, not two operations:

| Script | The two forms | Why it is one job |
|---|---|---|
| `worktree-catch-up.sh` | `--with`, `--abort` | one event, one merge; the evaluators' closest call, kept |
| `flow-candidates.sh` | steps, `--stages` | two views of one catalogue read |
| `flow-end.sh` | done, dropped | one event; "dropped" only adds the human's words |
| `flow-show.sh` | one flow, all of an effort's | the same view, narrower or wider |
| `show-card.sh` | plain, recorded | one act, showing a card; the record is an option |
| `gate-answer.sh` | one answer, a list by prefix | two reads of one event with the same rules |

`gate-answer.sh` is the one to watch. It gained its second form today. A third would make it a hub, and that is the moment to split it, not before.

**No unnatural split.** Five internal scripts have exactly one caller, which is where an unnatural split would show. Each passes the test:

| Script | Its one caller | Why it stands |
|---|---|---|
| `worktree-setup.sh` | `worktree-cut.sh` | two paths in, lines out, nothing private; changes for its own reason |
| `check-question-shape.sh` | the gate's hold hook | its own contract and evidence; hooks on one matcher run side by side, so it can't be a hook of its own |
| `effort-commits.sh` | `mount-apply.sh` | a read-only proof with a one-line contract; its odd part went to git-commit today |
| `commit-snapshots.sh` | `effort-commits.sh` | one caller, but it is the one home of a rule another component needs |
| `worktree-changes.sh`, `worktree-uncommitted.sh` | git-worktree's library | reached through the library by several scripts, so several users in fact |

Everything else internal has two or more callers. The setup chain, which was the one unnatural split, is merged.

**The four `open-work.sh` scripts** have no caller by name. That is right: `effort-close.sh` finds them by their place in each component, which is how core stays ignorant of the domain.

## Rule 2: main's scripts and the rest

**Internal: nothing there is for main.** No skill, step file or `CLAUDE.md` names an internal script. Every internal script is called by a script, a hook, or found by its place.

**Main: every script there has a use for main.** Fourteen main scripts are also called by other scripts, which is where a misplaced one would hide. I read each help; each states what main uses it for:

- `push-remote.sh`: the remote's URLs for the push card;
- `worktree-snapshot.sh`: basing work on the checkout as it is;
- `worktree-chain.sh`: seeing whether a tree is behind its sources;
- `worktree-facts.sh`, `worktree-catch-up.sh`, `worktree-discard.sh`, `mount-undo.sh`: main's own operations, reused by a neighbour;
- `tracker-read.sh`: reading an issue without adding it;
- `context-docs.sh`, `context-path-check.sh`, `effort-state.sh`, `commit-message.sh`, `identity-get.sh`, `identity-list.sh`: read by main and by neighbours alike.

That matches the rule we agreed: where main and a neighbour both use a script, it lives in `main/`.

**Hooks** are in `hooks/`, run only by the harness. **The two install scripts** are outside the rule on purpose: a human or the install runs them, not main.

## The one thing to tidy

Six main helps name a script main can't reach. The read hook denies main both running and reading it, so each mention is a pointer to a closed door:

- `worktree-catch-up.sh`, `worktree-chain-sync.sh`, `worktree-drop.sh`, `worktree-move.sh`: "not busy (worktree-busy.sh)";
- `worktree-diff.sh`: "base as worktree-trees.sh reports it";
- `commit-message.sh`: "the message file for commit-tree.sh, commits-merge.sh or commit-object.sh".

The fix is words only: say the condition plainly ("nothing is working in the tree"), and name a main script where one gives the fact (`worktree-facts.sh`). The help checker could refuse a main help that names an internal script; that would keep it so. Small, and it changes no behaviour.

## One recorded gap, unchanged

`worktree-busy.sh` asks every installed component's `scripts/internal/busy.sh`, and no component has one yet. That is the "busy scan with no answer" already recorded as designed, not built. It belongs to agent-run.

## What this does not show

Placement and shape are right as far as callers and helps can show. Whether main finds what it needs in `scripts/main/` alone is a question for the next live run.
