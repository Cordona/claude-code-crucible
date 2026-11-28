# Git worktrees as a floating piece: design

> **Owner decisions after this design (2026-11-22), to be written in before the build:**
> 1. **Cutting trees is always a step.** No quiet cuts. Whenever a job writes, main proposes `cut-worktree`. One card lists every tree for the dispatch (name, repository, what each is cut from) behind one gate. Each tree still ends in its own `worktree.cut`. Written into sections 2, 3 and 4.2; section 6 keeps how the middle way was first agreed.
> 2. **The agent-run logic is parked, not dropped** (revised the same day: "we stay very focused on the WT stuff and move the agent run stuff when time is ready"). The stop-hook chain (report check, commit-message input from the report, the commit through `git-commit`, `build.committed` and `test.committed`, the blocked-stop relay that wakes the agent), the write-scope hooks (a builder never writes tests, a tester only tests), and `commit-input.sh` go later into a domain component, `agent-run`, which knows agents and trees and calls the git components by path. Every old file it covers, and every other non-tree part of the old tree, is mapped in `agent-run-parked-map.md` beside this design, so nothing slips. Now: everything about trees, merging included, moves into the four git components.
> 3. **The old misplacement** (worktree scripts holding agent things, seat-run holding git things) is corrected by this split: `git-commit` signs commits, `git-worktree` handles trees, `agent-run` handles what happens when an agent stops.
>
> **Next:**
> - done: the map (`agent-run-parked-map.md`), its 8 gaps written into 4.2 and 4.3, the cut step changed, Fable's review and its five changes written in;
> - then the owner's go.

Agreed between Beta and Fable on 2026-11-22, at the owner's request; section 4 was extended the same day on the owner's word that every old tool moves across. Nothing is built before the owner's go.

## 1. What it is for

An agent that writes code works in its own git worktree, never in the human's checkout. This piece is a toolbelt main uses to prepare those trees:
- read the facts;
- cut a tree from the right base;
- drop a tree once it is no longer needed.

It knows nothing of agents, jobs or dispatch. It writes facts, `worktree.cut` and `worktree.dropped`, and the dispatch piece reads them later.

**Home:** `new-rewrite/domains/software-development/core/main-thread/git-worktree/`, a domain component beside `git-identity`. It reaches core only through core's public scripts.

## 2. The pieces

| File | Its one job | Writes |
|---|---|---|
| `scripts/worktree-facts.sh --repo DIR [--effort F]` | The facts main reasons from: the repository (resolved as in git-identity, the top folder of git's common directory); its HEAD; whether the checkout has uncommitted changes and how many; with `--effort`, the effort's live trees in that repository, their HEADs, and which of their tips the checkout and each other tree don't hold yet. Reads only. | nothing |
| `scripts/worktree-snapshot.sh --repo DIR --effort F` | One commit object of the checkout's uncommitted work, signed as the effort's identity for the repository through `git-commit`. With no identity set, it refuses: set the identity first. No ref, index or file of the human's is touched. Ported from the old `snapshot.sh`. | nothing; prints the sha and whether it is signed |
| `scripts/worktree-setup.sh --from CHECKOUT --to TREE` | Copies what git doesn't carry into a new tree. Dependency folders (`node_modules`, `vendor`, virtual envs, with their launchers repointed) are copied by default. Anything that can hold a secret (`.env*`, `.npmrc`, `auth.json` and the like) is copied only when the repository's own `.worktreeinclude` lists it. Ported from the old `worktree-setup.sh`. | the tree's files |
| `scripts/worktree-cut.sh --effort F --repo DIR --name NAME --from checkout\|snapshot\|worktree:NAME\|ref:REF` | Resolves the base itself (for `snapshot`, by running `worktree-snapshot.sh`; `--from worktree:NAME` may be repeated, and several trees' tips are joined into one base with `git-commit/commits-merge.sh`), creates `<effort>/worktrees/<name>` on the branch `crucible/<effort folder name>/<name>`, and runs `worktree-setup.sh`. It writes `worktree.cut` only when both succeeded. If the setup fails, it removes the tree, so no half-made tree is left behind an event. The git part is ported from the old `worktree-create.sh`. | `worktree.cut` |
| `scripts/worktree-drop.sh --effort F --name NAME` | Removes the tree, its git registration and its branch. When the branch holds commits the checkout lacks, it needs a recorded yes. It still works when the tree's folder was already deleted by hand. | `worktree.dropped` |
| `scripts/open-work.sh --effort F` | One line per live tree, for `effort-close.sh` | nothing |
| `events/worktree.cut.jq`, `events/worktree.dropped.jq` | The rules | |
| `flow-step.json` | `cut-worktree`, stage `setup`, ends with `worktree.cut`, skills `["git-worktree"]`, proposed whenever the coming work writes code (see 3) | |
| `SKILL.md` | The how | |

**A tree's name:** lowercase words joined by dashes, unique among the effort's live trees. Main chooses it. The sender later says which tree a job works in, so several jobs (a builder and its tester) can share one tree.

**`worktree.cut`:** `{name, repo, path, branch, base, from, signed?}`; `signed` is there when the cut made its base (a snapshot or a join of several trees).
- `from` is what was asked for (`checkout`, `snapshot`, `worktree:<name>` or `ref:<ref>`).
- `base` is the sha the script resolved from it. Both are true by construction.
- Readers: the facts script and the drop (`name`, `path`, `branch`, `repo`), the sender (`path`, `branch`), and the human (`from`, `base`).

**`worktree.dropped`:** `{name, answer?}`.
- `answer` is the seq of the recorded yes when the drop needed one, used once, as `spec.approved` and `identity.set` do.
- That way one yes drops exactly one tree, and the log shows which drops were the human's decision.

## 3. How main uses it

1. **Does the job write?** If yes, it needs a tree. If not (a reviewer, a reader), none.
2. **Facts:** `worktree-facts.sh`. The base options are:
   - the checkout's HEAD;
   - a snapshot, when the checkout has uncommitted changes;
   - another tree's work, when this job builds on it;
   - a named ref.
3. **Cutting is always a step; no tree is cut quietly.** Whenever the coming work writes code, main proposes `cut-worktree` in the flow. One free-form card lists every tree the coming work needs: each one's name, repository and what it is cut from, with the script's facts, main's reasoning and its recommendation. The human decides at one plain gate for all of them. Each tree then ends in its own `worktree.cut`.
   - **N trees are N step lines.** One event ends one step, so three trees are three `cut-worktree` steps in the flow. A flow holds step keys and no free text, so the flow card prints the same line three times; the trees' names are on main's card.
   - **The rule is enforced at dispatch,** like every flow rule. The sender refuses a tree whose `worktree.cut` is not the evidence of a done `cut-worktree` step of the agreed flow. This piece knows nothing of flows.
4. **Cut:** `worktree-cut.sh`, with the name and `--from`.
5. **Dispatch** (the sender, still to come) reads the tree's `worktree.cut` and gives the agent its path:
   - **a builder** gets its own tree;
   - **a tester** works in its builder's tree;
   - **a reviewer** gets no tree of its own, but the builder's tree's event, since that is where the work it reviews lives.

   Two agents writing in one tree at once is the sender's rule to prevent.
6. **Close:** `open-work.sh` lists every live tree, so closing an effort means dropping its trees, or closing with `--leave-open` on the human's word.
7. **Drop:** with nothing unlanded, it needs no gate. With unlanded commits, the gate's accept form is used, with record `drop-worktree` and the subject pinning the tree's name and its branch tip, so the yes is for exactly those commits. Until landing exists, every tree that holds commits counts as unlanded.

**The cut gate is plain, not recorded.** A cut is local, inside the effort folder, and reversible, and no later script acts on "the human chose this base". The event states what the tree was cut from.

**Nothing that walks effort folders goes into `worktrees/`.** The flow hook, the effort list and pruning read `events/` only. The effort folder now holds whole checkouts, and that must stay true.

## 4. The rest of the toolbelt (owner, 2026-11-22: "I do not want anything to slip")

Every tool of the old procedure moves to the new rewrite now, free of seats and agents. Committing goes with the agent-run piece, which doesn't exist yet. Its scripts are ported regardless, into a component of their own, and folder names can change later.

### 4.1 Four git components beside `git-identity`

Each has its own stake and changes alone. The dependencies run one way: worktree and mount use commit; commit uses identity; push reads worktree's events.

| Component | Its stake |
|---|---|
| `git-commit` | Making a signed commit object: from a tree's changes, or from several commits. The one home of signing. |
| `git-worktree` | Local trees: facts, snapshot, cut, setup, move, catch-up, chain, chain-sync, diff, discard, drop |
| `git-mount` | The human's working tree: putting a tree's work there to try it, and taking it out again |
| `git-push` | Going public: pushing a tree's branch |

Landing on the human's branch, by merge, rebase or pull request, stays the human's own step. That is why the component is called `git-mount` and not "land": nothing in it merges.

### 4.2 The new scripts

**`git-commit`:**

| Script | Its one job |
|---|---|
| `commit-message.sh --input F --out F` | A commit message from `{kind, text, trailers}`: `crucible(<kind>): <text>` plus trailers. No git. |
| `commit-tree.sh --worktree DIR --message-file F --effort E` | Stages and commits every change in a tree on its `crucible/` branch, signed as the effort's identity for the repository (read through `identity-get.sh`), with no hooks. It finishes a merge that is under way. |
| `commit-object.sh --repo DIR --tree T --parent P... --message-file F --effort E` | One signed commit object from a tree and its parents, for the snapshot and the discard. It writes git objects only: no ref, index or file moves. |
| `commits-merge.sh --repo DIR --commit C... --message-file F --effort E` | Merges several commits into one signed commit object (`git merge-tree`). It writes git objects only. |

- **The signing fallback:** after 10 seconds a commit is made unsigned. A blocked hook would be worse. Both scripts then print `signed: false` in their output, so whichever event reports the commit carries it, and the human sees it.
- **The snapshot, discard, catch-up, chain-sync and mount** call these scripts by path. None of them signs on its own.

**`git-worktree`,** beyond section 2:

| Script | Its one job | Writes |
|---|---|---|
| `worktree-move.sh --effort F --name N --to REF` | Moves a clean tree's branch to another commit for new work (`git reset --keep`). When commits would be left out, it first saves the old tip under `refs/crucible/moved/<effort>/<name>/<n>`. | `worktree.moved {name, from, to, kept?}` |
| `worktree-catch-up.sh --effort F --name N --with REF \| --abort` | Takes a commit into a tree's branch: a signed sync commit when clean (through `commits-merge.sh`), left mid-merge in the tree on a conflict for whoever works there, or `--abort` to cancel a merge left there | `worktree.synced {name, with, result: in_sync \| merged \| conflict \| aborted, commit?, signed?}` |
| `worktree-diff.sh --effort F --name N [--base SHA]` | Reads only. The tree's work as a reviewer reads it: commits, changed files and `git diff base...tip`, the base taken from `worktree.cut`, or the last `worktree.moved` when the tree moved | nothing; prints the diff file's path |
| `worktree-discard.sh --effort F --name N` | Clears a tree's uncommitted changes (tracked and untracked) without losing them: it first saves them as a commit (the snapshot's logic, through `git-commit`) under `refs/crucible/discarded/<effort>/<name>/<n>`, then resets the tree to its tip. Nothing is destroyed, so a plain gate is enough; `worktree-drop.sh` removes the kept ref later under its own recorded yes | `worktree.discarded {name, kept, signed}` |
| `worktree-chain.sh --effort F --name N` | Reads only. The trees this tree was cut from, directly and further back (each `worktree.cut`'s `from: worktree:<name>`), each with its tip and whether this tree already holds it. | nothing |
| `worktree-chain-sync.sh --effort F --name N` | Takes into a tree every ancestor that moved: it runs `worktree-chain.sh`, joins the moved tips with `commits-merge.sh` when there are several, then runs `worktree-catch-up.sh`. Whether and when to sync is main's and the human's. | through catch-up |

**An effort's folder is never deleted while it has live trees,** or a tree's registration, branch and kept refs would be left in the repository behind it. Closing already refuses through `open-work.sh`. The new core has no prune yet; when one comes, it asks the same `open-work.sh` checks and refuses the same way. The human drops each tree through the usual drop, with its gate.

**`worktree-drop.sh` also removes the tree's kept refs** under `refs/crucible/moved/…` and `refs/crucible/discarded/…`, with its branch. It needs the same recorded yes when they hold unlanded commits. Nothing is left in the repository forever.

**`git-mount`:**

| Script | Its one job | Writes |
|---|---|---|
| `mount-apply.sh --effort F --name N...` | Applies one or more trees' work (their tips joined by `commits-merge.sh` when there are several) to the human's working tree as a patch. It never touches the index or refs. It keeps the record, the patch and copies of what it replaced under `<gitdir>/crucible/`. | `mount.made {repo, names, target, start, paths}` |
| `mount-undo.sh --repo DIR` | Reverses the mount byte for byte, or, when the human already committed it, only drops the record | `mount.undone {repo, forgotten}` |
| `mount-status.sh --repo DIR [--effort F]` | Reads only. The mount's state: trees that moved since, whether HEAD moved, whether it is finished, which paths the human edited. | nothing |
| `effort-commits.sh --repo --from --to --effort F` | Reads only. Proves every commit in a range carries this effort's `Effort:` trailer, or is its snapshot. | nothing |
| `open-work.sh --effort F` | One line per mount of this effort still in place, for `effort-close.sh` | nothing |
| `lib/mount.sh` | The record's shape, carrying a version; the path states; restoring saved copies. A record of any other version is refused, never read as this one | |

- **Whether something is mounted is answered from the gitdir record, never by replaying events.** The record is the state: it holds the patch and the replaced files, and lives with the checkout. The human can also change it outside any effort, by undoing by hand or by committing the result.
- **The events are history:** a mount was made by this effort, of these trees.

**`git-push`:**

| Script | Its one job | Writes |
|---|---|---|
| `push-tree.sh --effort F --name N --remote R` | Pushes a tree's `crucible/` branch to the same name: never a protected branch, never prompting, with a timeout. It first checks the remote exists and is not the repository itself (ported from the old `origin-lib.sh`). It uses force-with-lease only when a `worktree.moved` is newer than the tree's last `push.made`. It needs the human's recorded yes, with record `push-tree`, subject `<name>:<tip>`, used once. | `push.made {name, remote, commit, answer}` |

Auto-push becomes a later setting. `push.made`'s rule accepts a push after the effort has ended, as the old core did, so a closed effort's tree can still go public.

**Steps declared** (a stage is a filter, never an order):
- `git-worktree/cut-worktree`, stage `setup`, proposed whenever the coming work writes code, all trees on one card;
- `git-mount/mount`, stage `deliver`, ends with `mount.made`;
- `git-push/push-tree`, stage `deliver`, ends with `push.made`.

Move, catch-up, chain-sync, diff and discard are tools main runs inside the work, not steps.

**A busy tree.** Drop, discard, move, catch-up and mount refuse a tree something is working in. They never read who: each asks every `busy.sh --effort F --name N` found in the components beside it, as `effort-close.sh` asks every `open-work.sh`, and refuses on any "busy" line it prints. No component answers yet; `agent-run` will, once agents work in trees. The scan is built now, so the old "idle seats only" check has its way back.

### 4.3 Every old file, and where it goes

| Old file | New home, or gone and why |
|---|---|
| `SKILL.md` | Replaced by a thin `SKILL.md` per component |
| `references/chains.md`, `move-and-catch-up.md`, `mount.md`, `push.md` | Gone: each script's `--help` is its contract, and the skills say when to use them |
| `references/sync-question.json`, `remount-question.json` | Gone: questions are built from the situation, through core's gate |
| `scripts/base/seat-base.sh` | Gone: replaced by `worktree-facts.sh` (including the tips not yet held) plus main's reasoning, and a repeatable `--from worktree:NAME` in the cut for a base joined from several trees |
| `scripts/cards/cards-lib.sh` | Gone: cards are core's gate's, or main's free-form ones |
| `scripts/commit/commit-input.sh` | Parked for `agent-run`: it turns an agent's report into the commit message input (`agent-run-parked-map.md`) |
| `scripts/commit/commit-message.sh`, `commit-message.jq` | `git-commit/commit-message.sh`, with a generic input |
| `scripts/commit/commit.sh` | `git-commit/commit-tree.sh` |
| `scripts/merge/tips-merge.sh` | `git-commit/commits-merge.sh` |
| `scripts/merge/catch-up.sh` | `git-worktree/worktree-catch-up.sh`, without seats or the builder's write scope (that belongs to the agent-run piece) |
| `scripts/merge/chain.sh`, `chain.jq` | `git-worktree/worktree-chain.sh`, from events instead of `base_seats` |
| `scripts/merge/chain-sync.sh` | `git-worktree/worktree-chain-sync.sh` |
| `scripts/mount/mount.sh` | `git-mount/mount-apply.sh` |
| `scripts/mount/mount-lib.sh` | `git-mount/lib/mount.sh`, without the seat-name pattern |
| `scripts/mount/unmount.sh` | `git-mount/mount-undo.sh`, without `seats.jq` |
| `scripts/mount/mount-status.sh` | `git-mount/mount-status.sh` |
| `scripts/mount/effort-commits.sh` | `git-mount/effort-commits.sh` |
| `scripts/push/push.sh` | `git-push/push-tree.sh`, without seats, on a recorded yes |
| `scripts/seats/seat-move.sh` | Gone: its seat bookkeeping goes; the move itself is `worktree-move.sh` |
| `scripts/seats/seat-open.sh` | Gone: replaced by `worktree-cut.sh` (create, then setup, then the event, rolled back on failure) |
| `scripts/worktree/dirty-check.sh` | Gone as its own question: the counts are in `worktree-facts.sh` |
| `scripts/worktree/snapshot.sh` | `git-worktree/worktree-snapshot.sh`, signing through `git-commit` |
| `scripts/worktree/uncommitted.jq` | `git-worktree/scripts/lib/uncommitted.jq`, shared by facts and drop |
| `scripts/worktree/worktree-create.sh` | The git part of `git-worktree/worktree-cut.sh` |
| `scripts/worktree/worktree-move.sh` | `git-worktree/worktree-move.sh` |
| `scripts/worktree/worktree-setup.sh`, `.jq`, `.json` | `git-worktree/worktree-setup.sh`, with its `.jq` and `.json`. Secret-holding entries move from the default list to the repository's opt-in. |
| `procedure-git-setup` (13 files) | The identity part is already `git-identity`. The push-remote check (`origin-lib.sh`) goes into `git-push/push-tree.sh`; the auto-push setting is later; the rest is its cards and prose, gone as above |
| `flow-code-review/scripts/request-review.sh`, its diff part | `git-worktree/worktree-diff.sh`; the review request itself is parked with the review flow |
| (none: the pair hold and a gave-up run needed it, done by hand) | `git-worktree/worktree-discard.sh` |
| `views/*.jq` (12 card templates) | Gone: script cards are core's, and these were seat-shaped. A result a script reports is printed as JSON, and main writes the card. |

### 4.4 Build order

Build in dependency order, each component with its own evidence run before the next starts:
1. `git-commit`;
2. `git-worktree`;
3. `git-mount`;
4. `git-push`.

Push's evidence runs against a scratch bare repository on disk, with no network and no login.

## 5. Evidence

Each run starts from `/` and uses a scratch repository, scratch keys (as in the git-identity run) and the installed layout. Nothing touches the owner's repositories or keys.

The cases:
- **Facts:** a clean checkout, a checkout with uncommitted changes, and the live trees.
- **Snapshots:**
  - a snapshot taken, with the checkout's files, index and refs unchanged;
  - refused without an identity.
- **Cuts:**
  - from `checkout`, from `snapshot`, from `worktree:<name>` and from `ref:<ref>`, each with `from` and `base` right in the event;
  - a name in use, refused;
  - a failing setup, which leaves no tree and no event.
- **Setup:**
  - `node_modules` and a virtual env copied;
  - `.env` not copied;
  - `.env` copied when `.worktreeinclude` lists it.
- **Drops:**
  - a clean drop with no gate;
  - unlanded commits refused without the recorded yes;
  - a drop with the yes, which carries `answer`;
  - the same yes refused on a second tree;
  - a drop after the folder was deleted by hand.
- **Close:** `effort-close.sh` refused while a tree is live, and allowed once it is dropped.
- **The flow:** the step listed under `setup`, and a flow with it ended by `worktree.cut`.
- **The rest of the toolbelt:**
  - a move that keeps the old tip;
  - a catch-up that is clean, one that is already in sync, one that conflicts, and one aborted;
  - a chain over two levels;
  - `commits-merge.sh` with a clean merge and with a conflict;
  - a commit in a tree, including finishing a merge;
  - a mount of one tree and of two;
  - an unmount, and one after the human committed;
  - the mount status after a tree moved;
  - an effort that won't close while its mount is in place;
  - a commit made unsigned after the timeout, reported as `signed: false`;
  - a chain-sync over two levels;
  - a drop that also removes its kept refs;
  - `effort-commits.sh` refusing a foreign commit;
  - a push refused without a recorded yes, accepted with one, and with a lease after a move, against a scratch bare remote.
- **Every other evidence run, unchanged.**

## 6. How it was agreed

Beta proposed the toolbelt. Fable approved the shape and changed six things:
- the cut and the setup are two scripts;
- a tree has its own name, not a job's;
- `--from`, so the base is derived;
- no getter before the sender;
- the snapshot's identity dependency is stated;
- secrets are copied only on opt-in.

Fable also added three:
- a recorded yes to drop unlanded work;
- a drop that works on a hand-deleted folder;
- nothing walking into `worktrees/`.

**On whether cutting is a flow step:**
- Fable would have left it out of the catalogue, to keep plumbing off the card.
- Beta kept it, because the owner asked for cuts as floating steps, and limited it to a real choice.
- Fable accepted that middle way. The owner can overrule it.

**Extended on the owner's word.** The owner did not accept leaving tools out ("I do not want anything to slip"). So section 4 ports every old tool now, free of seats:
- move, catch-up, chain and the merge of several commits, in `git-worktree`;
- the commit tools, in a new `git-commit` component for the agent-run piece;
- mount, unmount, status and the effort-commit proof, in a new `git-land`;

(That was the first form. Fable's review moved the merge into `git-commit` and renamed `git-land` to `git-mount`, as below.)
- push, in a new `git-push`, on a recorded yes.

Fable reviewed it and changed six things, all in section 4:
- **Names:** `git-mount`, not "land", since nothing merges. `mount.made` and `mount.undone`. `push.made`, so the event carries its writer's name. The stage is `deliver`.
- **Signing lives in `git-commit` alone,** and an unsigned fallback reports `signed: false`.
- **Chain-sync is a script,** because it is execution with no judgement.
- **The drop removes the kept refs.**
- **Every old file is mapped** in 4.3.
- **The build order** is in 4.4.

Also, whether something is mounted is read from the record, never from events, and `git-mount` has an `open-work.sh`.

**Revision (2026-11-22), after the parked map.** Fable reviewed the always-a-step cut, the map and its eight gaps: agree with five changes, all taken.
- The cut gate stays plain; "no quiet cuts" is enforced by the sender.
- N trees are N step lines, the names on main's card.
- Discard keeps the uncommitted work under a ref, so it needs no recorded yes.
- A neighbour scan, `busy.sh`, replaces the stripped "idle seats only" check.
- The step's `propose_when` no longer says "job".
- Noted: `git-worktree` holds twelve scripts, one stake; if it grows again, the sync group (catch-up, chain, chain-sync) is the part to split off.
