# The rewire, the plugins as skills, the base helper: Fable's review (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** in `new-rewrite/`: `jobs/track/scripts/lib/jobs.jq` (the view), `jobs/assign/events/job.assigned.jq`, `agent-init/scripts/lib/agent-type.sh`, `job-tree.sh`, the kinds' files and where `known_failures` is handled. I compared the 50 plugin skills' names with the names in the owner's `~/.claude/skills` (a listing only).

**Not done:** nothing was run. The evidence counts are Dev Beta's; I opened none of the six run outputs. I did not read how the installer links a skill.

## Verdict

**The rewire is as designed and smaller than I feared.** The view is one def of about ten lines; only `jobs.jq` and the `job.assigned` rule know there are two chains; nothing names `agent-jobs`. The base helper is the right answer to the cheap-test question.

**Two things before the live run means anything for a real install, and three smaller findings.**

## 1. Before any real install (not before the live run in a scratch config)

**1. Eight plugin skills carry names the owner already has installed.** Checked by name: `language-shell`, `standard-clean-code`, `standard-observability`, `standard-performance`, `standard-persistence`, `standard-security`, `standard-self-documenting-code`, `standard-testing`. Linked by name at user level, each either replaces a skill the owner's other sessions load, or is blocked by it. I did not check which of the two the installer does. The owner decides: a prefix for the new ones, or the old ones retired.

**2. The tree hook still refuses every tree start that no job claimed** ("trees here are made for jobs"). At user level that is every other session's tree isolation. It needs to step aside instead, and if a tree hook can't, the owner needs to know before anything is installed for real.

## 2. Three findings in what was built

**1. The lens is "the first standard".** The view gives a reviewer its lens as `plugins.standards[0]`. That is a meaning hidden in a list's order: a review with standards `[clean-code, security]` silently becomes a clean-code review, and its finding IDs follow. Nothing in `kinds/review.json` or resolve says a review takes one standard. Either resolve refuses a review with more than one, or the lens is said outright. A script check, one line.

**2. `known_failures` went into `work`.** It is checked at resolve and allowed by the rule, and it is simple. But it was blocker 3, "shape for the owner", and `work` was the tree, the range and the loop. If the owner approved it there, fine; if not, it is a shape that changed without the approval, and it should be shown before the live run.

**3. One guard from the tree run is not in the rule.** There the `job.assigned` rule itself refused a second cut job on one tree, independent of the door. Now the rule checks that the tree is a `worktree.cut` and matches a `use`; that a fresh cut is no other job's is the door's check alone. The door's note is the real guard and I said so then. Record that the second net is gone on purpose, or put the one line back.

## 3. What I checked and agree with

- **The view.** Built from `job.defined`, `job.assigned` and `worktree.cut`; the old event passed through as written. One def, and its comment says what the agent side may read. This is the contract I asked for.
- **`job.assigned` in two shapes.** Each branch names its writers and its fields; the shared checks (assigned once, one job per agent) run for both. It reads clearly as temporary.
- **The base from the type's name** (`agent-type.sh`). It reads no event, so every other agent's tool call passes at the cost of a folder test. Cheaper than what I proposed (the base from the open job's kind), and in one home. Agreed.
- **The plugin descriptions.** One short line each, "for a job agent … Not for main": about 5 KB for all 50 in a session's list. Two `disable-model-invocation` lines remain somewhere under `new-rewrite/`; check they are not plugins.
- **The move.** No file names `agent-jobs`; the folder is gone.

## 4. For the live run

The pass lines I would hold it to, beyond the chain being complete:
- each real agent's plugins byte-equal and loaded once, as in the spikes;
- about one Agent call per job, and main reading only the two thin skills;
- a review job's lens is what the human approved on the card (finding 1);
- no tracker call with the owner's login anywhere in it, and a scratch configuration, never the owner's.

## 5. For the owner

1. **The eight names** (section 1): prefix the new skills or retire the old.
2. **`known_failures` in `work`** (section 2): confirm, or say where it goes.
