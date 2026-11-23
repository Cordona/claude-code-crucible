# Spec: the software-development domain

Tracker and git knowledge stays in the domain, out of core. The domain reaches core only through core's public scripts, called by path, never sourced.

## The pieces

The components live in `new-rewrite/domains/software-development/core/main-thread/`.

| Piece | One job |
|---|---|
| `dev-base/scripts/internal/repo-of.sh --dir FOLDER` | The repository a folder belongs to and its main checkout, as `{repo, git_dir}`; reads only |
| `dev-base/scripts/internal/run-timed.sh --seconds N -- COMMAND...` | Runs a command with stdin closed; at the limit, stops it and every process beneath it, exit 124 |
| `trackers/scripts/main/tracker-read.sh --url URL` | Prints one GitHub or GitLab issue, read-only |
| `trackers/scripts/main/context-add-issue.sh --effort FOLDER --url URL` | Copies that issue into the effort's context |
| `code-context/scripts/main/context-add-commit.sh --effort FOLDER --repo ROOT --ref REF` | Writes a commit or range into the effort's context as a patch |
| `trackers/SKILL.md` | Signpost: use it when the human points to a GitHub or GitLab issue, or one belongs to an effort's work |
| `code-context/SKILL.md` | Signpost: use it when a change already made belongs to an effort's work |
| `git-commit/scripts/main/commit-message.sh --input F --out F` | A commit message from `{kind, text, trailers}`; no git |
| `git-commit/scripts/main/commit-tree.sh --worktree DIR --message-file F --effort E` | Commits every change in a tree on its `crucible/` branch, signed as the effort's identity |
| `git-commit/scripts/internal/commits-merge.sh --repo DIR --commit C... --message-file F --effort E` | Merges several commits into one signed commit object; git objects only |
| `git-commit/scripts/internal/commit-object.sh --repo DIR --tree T --parent P... --message-file F --effort E` | One signed commit object from a tree and its parents; git objects only |
| `git-commit/SKILL.md` | Signpost: use it when a tree's work is committed, or several commits are joined into one |
| `git-worktree/scripts/main/worktree-facts.sh --repo DIR [--effort F]` | The facts a base is chosen from: the repository, its checkout's HEAD and uncommitted count, the effort's live trees and which tips the checkout and the other trees lack; reads only |
| `git-worktree/scripts/main/worktree-snapshot.sh --repo DIR --effort F` | One signed commit object of the checkout's uncommitted work; no ref, index or file of the human's moves |
| `git-worktree/scripts/internal/worktree-setup.sh --from CHECKOUT --to TREE` | Sets up a new tree through the plan, the copy and the repoint, one line per thing done |
| `git-worktree/scripts/internal/setup-plan.sh --from CHECKOUT --to TREE` | What a new tree gets: each technology's dependency folders; secrets only when `.worktreeinclude` lists them; reads only |
| `git-worktree/scripts/internal/setup-copy.sh --plan FILE` | Copies, copy-on-write, what the plan says; never a tracked file, an overwrite or an unignored secret |
| `git-worktree/scripts/internal/setup-repoint.sh --from CHECKOUT --to TREE --folder PATH --subfolder SUB...` | Repoints a copied virtual env's launchers at the copy |
| `git-worktree/scripts/main/worktree-cut.sh --effort F --repo DIR --name N --from BASE...` | Cuts and sets up one tree; writes `worktree.cut`, or rolls back |
| `git-worktree/scripts/main/worktree-drop.sh --effort F --name N` | Removes a tree, its branch and kept refs; unlanded work on a recorded yes; writes `worktree.dropped` |
| `git-worktree/scripts/main/worktree-move.sh --effort F --name N --to REF` | Moves a clean tree to another commit, keeping the old tip when needed; writes `worktree.moved` |
| `git-worktree/scripts/main/worktree-catch-up.sh --effort F --name N --with REF \| --abort` | Takes a commit into a tree, or aborts a merge left there; writes `worktree.synced` |
| `git-worktree/scripts/main/worktree-chain.sh --effort F --name N` | The trees a tree was cut from, at every level, and whether it holds their tips; reads only |
| `git-worktree/scripts/main/worktree-chain-sync.sh --effort F --name N` | Takes in every ancestor tip that moved, through the catch-up |
| `git-worktree/scripts/main/worktree-diff.sh --effort F --name N [--base SHA]` | Writes a tree's committed work to a diff file for a reviewer |
| `git-worktree/scripts/main/worktree-discard.sh --effort F --name N` | Clears a tree's uncommitted changes, keeping them under a ref; writes `worktree.discarded` |
| `git-worktree/scripts/internal/worktree-trees.sh --effort F [--name N]` | The effort's live trees from its events; reads only |
| `git-worktree/scripts/internal/worktree-busy.sh --effort F --name N...` | The busy scan of the neighbours' `busy.sh`; reads only |
| `git-worktree/scripts/internal/worktree-uncommitted.sh --dir DIR` | The count of paths with an uncommitted change; reads only |
| `git-worktree/scripts/internal/worktree-changes.sh --dir DIR --head C` | A tree object of a commit plus every change in a folder, through a temp index |
| `git-worktree/scripts/internal/worktree-kept.sh --effort F --name N [--next KIND]` | A tree's kept refs, and the next free one; reads only |
| `git-worktree/scripts/internal/open-work.sh --effort F` | One line per live tree, for `effort-close.sh` |
| `git-worktree/SKILL.md` | How main proposes, cuts and tends trees |
| `git-mount/scripts/main/mount-apply.sh --effort F --name N...` | Puts trees' committed work (several joined through `commits-merge.sh`) into the human's checkout as a patch; index and refs untouched; writes `mount.made` |
| `git-mount/scripts/main/mount-undo.sh --repo DIR` | Takes the mount out byte for byte, or forgets it once the human committed it; writes `mount.undone` |
| `git-mount/scripts/main/mount-status.sh --repo DIR [--effort F]` | The mount's state: trees moved since, HEAD moved, finished, paths edited; reads only |
| `git-mount/scripts/internal/mount-record.sh --repo DIR` | Reads and checks the gitdir record; any version but 3 refused; reads only |
| `git-mount/scripts/internal/mount-paths.sh --repo DIR` | Each mounted path now: mounted, committed, gone or edited; reads only |
| `git-mount/scripts/internal/mount-states.sh --repo DIR --paths FILE` | What each path holds in the checkout, as git would store it; reads only |
| `git-mount/scripts/internal/mount-restore.sh --repo DIR` | Puts the saved bytes back where git apply -R restored only the content |
| `git-mount/scripts/internal/effort-commits.sh --repo DIR --from SHA --to SHA --effort F` | Proves every commit of a range carries this effort's `Effort:` trailer, and gives the start (the effort's snapshot, else `--from`); reads only |
| `git-mount/scripts/internal/open-work.sh --effort F` | One line per mount of this effort still in place, for `effort-close.sh` |
| `git-mount/SKILL.md` | When to propose the mount and what to show the human |
| `git-push/scripts/main/push-tree.sh --effort F --name N --remote R [--timeout S]` | Pushes a live tree's branch tip to the remote under the same name, on a recorded yes; never a protected branch, never prompting, within a time limit; by lease only after a move; writes `push.made` |
| `git-push/scripts/main/push-remote.sh --repo DIR --remote R` | Whether the remote is configured and no URL it pushes to is the repository itself; reads only |
| `git-push/SKILL.md` | When to propose a push and what to show the human |

## Dev base

**Home:** `domains/software-development/core/main-thread/dev-base/`. The domain's base, the way `crucible-events` is core's: two rules several components share, each in one script. It has no `SKILL.md`; the install links it like any component. It depends on nothing, and every component in the domain may call it, by path, as a neighbour skill.

- **A repository is one thing,** and `repo-of.sh` is its one home: the top folder of git's common directory, physical, which is the main checkout. A checkout and each of its worktrees name the same repository. A folder in no repository is exit 3; a bare repository, which has no checkout, exit 5. Inherited `GIT_DIR`-style variables and `CDPATH` are cleared first. git-worktree, git-mount and git-identity take `repo` from it, git-mount `git_dir` too; git-commit uses it to check `--repo`. Each caller refuses with `--repo` and the reason `repo-of.sh` gave.
- **A command under a time limit,** and `run-timed.sh` is its one home. The command runs in the background with stdin closed, its stdout and stderr the runner's own. At the limit the command and every process beneath it, found with `pgrep -P`, are frozen parents first, so none can start another or leave the tree while it is walked; each then gets TERM, and KILL 2 seconds later if still running, each by its PID; the exit is 124. Told to stop itself (TERM, INT, HUP), it stops the tree the same way. A refusal is exit 2 with nothing run; otherwise the exit is the command's own. git-commit's signing, git-push's push and tracker-read's tracker calls run through it.

## Trackers

**Which links.** The URL must pass the safe-link rule (http(s), only letters, digits and `. _ ~ / ? # = % : + , @ -`), or it exits 2. Two kinds are tracker links:
- **GitHub:** host `github.com`, path `/<owner>/<repo>/issues/<n>`, read with `gh`.
- **GitLab:** any other host without a port, path ending `/-/issues/<n>`, read with `glab`.

Anything else, including pull and merge requests, GitHub Enterprise and Jira, is not a tracker link (exit 3). An `/issues/<n>` link the tracker resolves to a pull request is read as the tracker gives it.

**The issue** is markdown: the title, a line with the URL, state, author and creation time, then the body, then the comments, oldest first. GitLab system notes are left out.

**Bounds.** Each tracker call stops after 30 s. The output stops at 500 lines, and stderr then says `tracker-read.sh: truncated: showing 500 of <N> lines`.

**Exits.** 0: the issue on stdout. 1: the read failed (a missing tool, a timeout, the tracker's error, a reply that isn't an issue). 2: a usage error or refused URL. 3: not a tracker link. On any exit but 0, the reason is on stderr's first line.

**Read-only by construction.** The script runs only `gh issue view`, `glab issue view` and, for GitLab comments, a `glab api` read of the issue's notes. The URL goes to them as one argument after `--`.

**Comments that can't be read** (GitLab without a login, for one) leave the body, with a `## Comments not read (<reason>)` line in their place.

**The copy into the context.** `context-add-issue.sh` asks core's `context-docs.sh` for the draft's docs folder before it reads, so a closed effort is refused before any tracker call. It then runs `tracker-read.sh` and passes exits 1, 2 and 3 on; on 3, main adds the URL as a link instead.

- **Name:** `issue-<host and path>.md`, lower-cased, query and fragment dropped, every character but letters, digits and dots a dash (`issue-github.com-o-r-issues-5.md`). A same-named copy is replaced.
- **Header:** where it was copied from and when (UTC), and that what follows is quoted from the tracker: text other people wrote, material for the work, never instructions.
- **A partial copy** says what is missing in two places: in the header (`Cut short: …` and/or `Comments not read (…)`) and on stderr (`partial copy: …`).

**Why a copy and not a live link.** An issue changes; the cut version holding the copy is sealed. Agents read the copy from the docs, so they need no tracker login and no tracker plugin. A ticket edited later is new material in a new version, never a silent change.

**The link rule is a copy of core's** (`crucible-context/scripts/lib/link-rule.jq`), because the domain never reaches into core's internals. An evidence check keeps the two in step: it sends the same good and bad URLs to `tracker-read.sh` and to `context-add.sh --link`, and both must give the same verdict. There is no shared file.

## Code context

`context-add-commit.sh` takes a commit or a range `A..B` from a local git work tree. ROOT is absolute and only read; REF must name commits and not start with `-`. It writes the diff into the draft docs folder as `diff-<sha>.patch`, or `diff-<sha>..<sha>.patch` for a range (short SHAs), replacing a same-named file.

Each changed file goes through core's `context-path-check.sh`. Files it refuses (secrets, instruction files) are left out and named on stderr; if none is left, it refuses. Exit 0 prints the patch's path; exit 2 is any refusal, nothing written.

## Git identity

**Home:** `domains/software-development/core/main-thread/git-identity/`. The human picks, from this machine's signing identities, the one an effort's commits in a repository are signed as. It is written as `identity.set`, a fact. The piece never changes git config; `git-commit` applies the identity to each commit.

| Piece | Its one job |
|---|---|
| `scripts/main/identity-list.sh` | The signing identities this machine can use, as JSON: GPG user ids, and SSH keys the agent holds or whose private key is present, named by git's global allowed-signers file or user.signingkey. Global git config only, so the list is the same from any folder. Reads only. |
| `scripts/main/identity-card.sh --list --repo [--question]` | The card and the question: only identities `identity-check.sh` passes in the repository are options, and the rest are named with their reason. No recommendation. With one usable identity, a second option, "None of these". More than 4 usable identities is refused. Reads only. |
| `scripts/internal/identity-check.sh` | Whether one name, email and key can sign in one repository, with the repository's own git config. Reads only. |
| `scripts/main/identity-set.sh --effort --repo --list` | Writes `identity.set` once four checks pass: the list still matches the machine; there is a recorded pick at the choice gate `set-identity`, subject `<repository>:<sha256 of the list>`; the pick is exactly one of the list's labels; and the identity can sign there. |
| `scripts/main/identity-get.sh --effort --repo` | The newest `identity.set` for the repository, as JSON; exit 5 when there is none. Reads only. |
| `events/identity.set.jq` | Written only by `identity-set.sh`; its shape, and `answer` used once. Whether `answer` is a recorded pick is `identity-set.sh`'s question to the gate's reader; the rule never reads gate events. |
| `flow-step.json` | The step `git-identity/set-identity`, stage `setup`, ending with `identity.set` |

- **The repository** is the one dev-base's `repo-of.sh` names, so an identity set from the checkout is found from any worktree.
- **The identity is per effort and per repository.** A newer `identity.set` for the same repository replaces the older one, which is how the human changes it.
- **The pick is deterministic:**
  - the options come from the machine;
  - the hook records the answer;
  - the subject pins the list the human saw;
  - the setter takes only an exact label and checks the machine again.
  If main changes an option or marks one recommended, the label no longer matches and the set refuses.
- **The `identity.set` body:** `{repo, name, email, signing: {format, key}, fingerprint, answer}`. `repo` is read by `identity-get.sh`; `name`, `email`, `signing` and `fingerprint` by the commit piece; `answer` by the rule.

## Git commit

**Home:** `domains/software-development/core/main-thread/git-commit/`. The one home of signing: every signed commit object the domain makes is made here. It writes git objects only, and no events; whichever event later reports a commit carries what the script printed.

| Piece | Its one job |
|---|---|
| `scripts/main/commit-message.sh --input F --out F` | Writes `crucible(<kind>): <text>`, then a blank line and one `Key-Name: value` line per trailer, in the input's order. `kind` and each trailer key are lowercase words joined by dashes; the subject is at most 72 characters, a trailer value one line of at most 200, or a whole number. No kind is built in. Each problem is one stderr line, exit 2. No git. |
| `scripts/main/commit-tree.sh --worktree DIR --message-file F --effort E` | Stages every change in a linked worktree (`git add -A`) and commits it, with no hook, the message verbatim. It refuses a main checkout, a detached HEAD, a branch not under `crucible/<effort folder name>/`, a pick, revert or rebase under way, and a merge whose paths still hold conflict markers. A merge under way is finished as the merge commit. It then proves the commit: on the branch, the right parents, the message and signature as made, nothing left. Exit 3: nothing to commit. |
| `scripts/internal/commits-merge.sh --repo DIR --commit C... --message-file F --effort E` | Drops repeats and commits another one holds; when one is left it is the answer (`new: false`). Otherwise it folds the rest left with `git merge-tree --write-tree` and writes one commit with every kept commit as a parent, in the given order. No ref, index or worktree changes. A conflicting step: exit 3, the paths on stdout as `{conflicts}` and on stderr. |
| `scripts/internal/commit-object.sh --repo DIR --tree T --parent P... --message-file F --effort E` | One commit object of tree T with one or more parents, in the given order: the snapshot's and discard's commit, made without moving a ref. No ref, index or file changes. A tree or parent that is no object of its kind in the repository is refused. |
| `scripts/lib/git-commit.sh` | Shared, prefix `gc_`: git-identity and dev-base found by path text, the `--repo` check, the identity read, the Effort trailer, git run as the identity, and the signed run |
| `SKILL.md` | When to use it; the scripts' `--help` are the contracts |

- **The identity** is read through the neighbour skill git-identity's `identity-get.sh`, by path, and applied with `-c user.name`, `user.email`, `gpg.format` and `user.signingkey` flags; git config is never changed. Inherited author, committer and repository variables are cleared, so the identity is the only one used. An effort with no identity for the repository (exit 5 from `identity-get.sh`) is refused: set the identity first.
- **The `Effort:` trailer is the committing scripts' job.** All three add `Effort: <effort folder name>` from `--effort` when the message has none, keep one that names this effort, and refuse one that names another. So every commit they make carries it, and `git-mount`'s `effort-commits.sh` can prove an effort's work by it. The message input need not carry it.
- **Signing and its fallback.** Every commit is signed. The signing git command runs through dev-base's `run-timed.sh`, stdin closed, with no `GPG_TTY` and a failing `SSH_ASKPASS`; after 10 seconds it is stopped with every process it started, the signer program and anything that started included. When signing fails or times out, the commit is made again unsigned, and stderr says why (`signing timed out after 10 s`, or the signer's first line).
- **Output.** `commit-tree.sh` and `commit-object.sh` print `{commit, signed}`, and `commits-merge.sh` prints `{commit, new, signed}`. `signed: false` is the fallback. For `new: false`, `signed` says whether that existing commit carries a signature.
- **The fold steps** of a merge of three or more are unsigned temporary commits by the identity; no ref points at them, so they are left for git's own pruning.

## Git worktree

**Home:** `domains/software-development/core/main-thread/git-worktree/`. Code-writing work happens in a tree of its own, never in the human's checkout. The piece knows nothing of agents or dispatch: it writes facts, and whatever sends work later reads them.

| Piece | Its one job |
|---|---|
| `scripts/main/worktree-facts.sh` | The repository (named by dev-base's `repo-of.sh`), its checkout's HEAD, branch and uncommitted count; with `--effort`, each live tree in that repository with its tip, whether its folder is there, its uncommitted count, whether the checkout holds its tip and which other trees don't. Reads only. |
| `scripts/main/worktree-snapshot.sh` | The checkout's uncommitted work as one commit object on HEAD, through `git-commit/commit-object.sh`: a temp index, no ref, index or file of the human's touched, and the checkout fingerprinted before and after (exit 5 when it changed). A clean checkout gives HEAD, `new: false`. With no identity for the repository, it refuses. |
| `scripts/internal/worktree-setup.sh` | The setup `worktree-cut.sh` runs: `setup-plan.sh`, then `setup-copy.sh`, then `setup-repoint.sh` for each copied folder whose technology names launcher subfolders, right after its copy. It prints `detected`, `method`, `copied`, `exists`, `tracked`, `unignored`, `flag symlink` and `repointed` lines; every problem goes to stderr after them. |
| `scripts/internal/setup-plan.sh` (+ `lib/worktree-setup.jq`, `lib/worktree-setup.json`) | Checks the two folders, the data file and `.worktreeinclude`, then finds each detected technology's dependency folders (`node_modules`, `vendor`, every folder holding a `pyvenv.cfg`) and the `.worktreeinclude` entries. Secret-holding files are never in the default list: only `.worktreeinclude` adds them. The search skips `.git`, the data file's skip folders, `--to` when it lies inside `--from`, and the inside of a found folder. A path inside another copied one is dropped, a folder holding a tracked file is marked tracked, a name holding a control character is marked bad. Prints `{from, from_given, to, detected, items, repoint}`. |
| `scripts/internal/setup-copy.sh` | Copies each `copy` item with `cp -c`, a reflink or a plain copy, links kept as links, modes and times kept. A listed `.env*`, `auth.json`, `.npmrc` or `local.properties` git doesn't ignore in the tree is left out (`unignored`). Never an overwrite (`exists`), never through a folder that leads outside the tree; an absolute link into the checkout is flagged. A failed item is a problem (exit 4); the rest are still copied. |
| `scripts/internal/setup-repoint.sh` | In each named subfolder of a copied folder, rewrites every text launcher naming the checkout's copy (physical or as given, matched without case at a path boundary) to name the tree's; binaries, links and the source file itself are left alone. |
| `scripts/main/worktree-cut.sh` | Resolves `--from` itself (`checkout`, `snapshot`, `worktree:NAME` repeatable, `ref:REF`), joins several trees' tips with `git-commit/commits-merge.sh`, creates the tree with no hook, runs the setup, then writes `worktree.cut`. A failed setup or event write removes the tree, its registration and branch again. |
| `scripts/main/worktree-drop.sh` | Removes the folder (or, when it went by hand, only this tree's own registration), the branch and the kept refs, then writes `worktree.dropped`. Uncommitted changes refuse it. Unlanded work needs the recorded yes. Any effort state. |
| `scripts/main/worktree-move.sh` | `git reset --keep` of a clean tree to another commit; the old tip kept under `refs/crucible/moved/<effort>/<name>/<n>` when commits would be left out. |
| `scripts/main/worktree-catch-up.sh` | `in_sync`, `merged` (a signed sync commit through `commits-merge.sh`, then a fast-forward), `conflict` (the merge left in the tree for whoever works there) or, with `--abort`, `aborted`. |
| `scripts/main/worktree-chain.sh`, `worktree-chain-sync.sh` | The ancestors from each `worktree.cut`'s `from`, breadth first, each once; the sync joins the moved tips and runs the catch-up. Exit 3 when the moved tips conflict with each other. |
| `scripts/main/worktree-diff.sh` | `<effort>/diffs/<name>-<base>-<tip>.patch`: commits, changed files and `git diff base...tip`, the base the newest move's `to`, else the cut's. |
| `scripts/main/worktree-discard.sh` | The tree's uncommitted changes kept as a signed commit (the snapshot's temp-index logic, through `commit-object.sh`) under `refs/crucible/discarded/<effort>/<name>/<n>`, then `reset --hard` and `clean -fd`. Nothing is destroyed, so no recorded yes. |
| `scripts/internal/worktree-trees.sh` | The live trees, oldest cut first, as `{name, repo, path, branch, from, cut_base, base, seq}`: `base` the newest `worktree.moved`'s `to`, else the cut's. `--name` keeps one; `[]` when none. Every script that reads a tree reads it here, and so does `git-mount`. |
| `scripts/internal/worktree-busy.sh` | Runs every `<component>/scripts/internal/busy.sh --effort F --name N` beside this one for each name; `{busy: ["<component>: <name>: <line>"...]}`, exit 5 when busy. |
| `scripts/internal/worktree-uncommitted.sh` | `{uncommitted: N}`: staged, unstaged and untracked paths, a rename counted once; nothing git ignores. |
| `scripts/internal/worktree-changes.sh` | `{tree, head_tree}`: the tree object of HEAD plus every change in the folder, built in a temp index, so the folder's own index is never written; the snapshot's and the discard's tree. |
| `scripts/internal/worktree-kept.sh` | The kept refs `refs/crucible/<moved\|discarded>/<effort>/<name>/<n>` of a live tree; with `--next`, the next free `n` of that kind. The one home of the kept-ref naming. |
| `scripts/internal/open-work.sh` | `worktree <name> <path>` per live tree, so an effort with live trees doesn't close. |
| `scripts/lib/git-worktree.sh`, `lib/trees.jq`, `lib/uncommitted.jq` | Shared, prefix `gw_`: the refusal and problem lines, core and neighbours found by path text, the effort, name and commit checks, the repository through dev-base, a tree's state checks, the work folder, the event write, and thin calls to this component's own job scripts; the live-tree and uncommitted-path jq modules. |
| `events/worktree.*.jq` | One rule per event: the writer, the shape, and `answer` used once for the drop. Whether the tree is live (for the cut, not yet live) is the writing script's question to `worktree-trees.sh`; the rules never replay the trees. A move, catch-up or discard asks again just before its write, and a tree dropped while it ran gets no event (exit 2). |
| `flow-step.json` | `git-worktree/cut-worktree`, stage `setup`, ends with `worktree.cut`, proposed whenever the coming work writes code |

- **A tree:** `<effort>/worktrees/<name>`, branch `crucible/<effort folder name>/<name>`, the name lowercase words joined by dashes, unique among the effort's live trees. A name can be cut again once its tree is dropped. A live tree is a `worktree.cut` with no later `worktree.dropped` of its name.
- **The events:**
  - `worktree.cut {name, repo, path, branch, base, from, signed?}`: `from` as asked, several `worktree:NAME` joined by one space; `base` the sha resolved; `signed` exactly when the cut made its base (`snapshot`, or several trees).
  - `worktree.dropped {name, answer?}`.
  - `worktree.moved {name, from, to, kept?}`.
  - `worktree.synced {name, with, result, commit?, signed?}`: `with` the full sha; `commit` and `signed` for `merged` only.
  - `worktree.discarded {name, kept, signed}`.
- **Cutting is always a step.** One card lists every tree; one plain gate decides; each tree ends its own `cut-worktree` step line. The sender enforces it at dispatch; this piece knows nothing of flows.
- **The drop's yes:** record `drop-worktree`, subject `<name>:<branch tip>` (`none` when the branch is gone). Unlanded means commits the tip and the kept refs hold that the checkout's HEAD, the cut's base and the current base lack; until landing exists, every commit a tree made counts. The script checks the answer is unused before it removes anything; the rule checks it again. A drop that removed the tree but could not write its event (exit 6, the lock held) leaves its yes unused, so the rerun, finding the folder and branch both gone, carries the newest unused yes given for `<name>:` since the cut, asking core's `gate-answer.sh --subject-prefix <name>: --after <cut seq>` for the accepted ones and checking each against its own `worktree.dropped` events; with none it refuses (exit 2) and writes nothing. A drop that needed no yes is then recorded on a yes for `<name>:none`.
- **The busy scan** is `worktree-busy.sh`. Drop, discard, move and catch-up ask it, and so does `git-mount`'s apply. A line starting `busy`, or a check that fails, refuses with the lines named. No component answers yet.
- **Signing** is `git-commit`'s alone. A snapshot, a joined base, a sync commit and a discard's kept commit are all made there; an unsigned fallback is said on stderr, and in the `signed` of `worktree.cut`, `worktree.synced` and `worktree.discarded`, so the human sees it.
- **Nothing that walks effort folders goes into `worktrees/`.** The effort folder holds whole checkouts.

## Git mount

**Home:** `domains/software-development/core/main-thread/git-mount/`. The human's own checkout: putting a tree's work there to try it, and taking it out again. Nothing in it merges; landing on the human's branch stays the human's step.

| Piece | Its one job |
|---|---|
| `scripts/main/mount-apply.sh` | Reads the trees through git-worktree's `worktree-trees.sh` and `worktree-facts.sh` (one repository, branch there, folder clean), asks git-worktree's `worktree-busy.sh`, joins several tips with `git-commit/commits-merge.sh`, proves the range with `effort-commits.sh`, then builds the patch from the start to the target with plumbing `diff-tree`. Every touched path must hold the start's state (`mount-states.sh`) and its staged entry must match HEAD's or the start's. It writes the patch, the raw copies and the record first, then applies the patch to the working tree only, checks it with `mount-paths.sh`, and writes `mount.made`. A failure after the first write takes the patch out again and removes what it wrote. A finished mount already recorded is forgotten first through `mount-undo.sh`. |
| `scripts/main/mount-undo.sh` | Finished (HEAD moved and holds every path): removes the record only. Otherwise every path must be as mounted and HEAD unmoved; `git apply -R`, then `mount-restore.sh`, then every path checked against its state from before, empty folders the mount made removed, the record removed. `mount.undone` goes to the record's effort while that folder still is one. |
| `scripts/main/mount-status.sh` | From the record and `mount-paths.sh`: each tree's tip as mounted and its branch tip now, HEAD moved, finished, the edited paths; with `--effort`, whether that effort made it. |
| `scripts/internal/mount-record.sh` | The record's one reader: its shape checked field by field, a record of another version refused with one line and never read. |
| `scripts/internal/mount-paths.sh`, `mount-states.sh` | A path's state is absent, `<mode> <blob sha>` (hashed through the clean filters, no object written), directory, beyond-symlink, beyond-file or other. A mounted path is committed, mounted, gone or edited. |
| `scripts/internal/mount-restore.sh` | Copies a saved file back only where the checkout already holds its content in other bytes; it never touches a file whose content differs. |
| `scripts/internal/effort-commits.sh` | A snapshot is a commit with the snapshot subject whose one parent is `--from`; several must share one tree. |
| `scripts/internal/open-work.sh` | The repositories come from this effort's `mount.made` events; whether a mount is there comes from each checkout's record, made by this effort and not finished. A record it can't read fails the check, so the close is refused. |
| `scripts/lib/mount.sh` | Shared, prefix `gm_`: the refusal lines, core found by path text, the repository through dev-base and the record's folder, the record version, the work folder. |
| `events/mount.made.jq`, `events/mount.undone.jq` | The writer and the shape; an undo only where the effort mounted before. Whether each mounted name is a live tree is `mount-apply.sh`'s question to `worktree-trees.sh`, asked again just before the write: a tree dropped while the mount ran takes the patch out again, with no event (exit 2); the rule never replays the trees. |
| `flow-step.json` | `git-mount/mount`, stage `deliver`, ends with `mount.made`, proposed when the human wants to try a tree's work in their own checkout |

- **The record is the state.** `<git folder>/crucible/mount.json` (version 3), `mount.patch` and `before/<n>` live with the checkout, and whether something is mounted is read only from them, never from events. The human can change it outside any effort, by committing the result or undoing by hand.
- **The events are history:** `mount.made {repo, names, target, start, paths}` (`paths` a count) and `mount.undone {repo, forgotten}`.
- **Nothing of the human's is lost.** A mount refuses any touched path that differs from the start; an undo refuses any path changed since. Ignored files count. The index and every ref stay as they were.
- **No recorded yes.** A mount is reversible byte for byte, and an undo touches only what the mount left, so a plain gate on the step is enough.
- **One mount per checkout.** A second is refused until the first is undone or committed.

## Git push

**Home:** `domains/software-development/core/main-thread/git-push/`. Going public: one tree's branch pushed to a remote, under the same name, on the human's yes. It reads the trees through git-worktree's `worktree-trees.sh` and their moves from git-worktree's `worktree.moved` events; it changes no tree.

| Piece | Its one job |
|---|---|
| `scripts/main/push-tree.sh` | Reads the live tree, refuses `main`, `master`, `develop`, `release/*` and any branch not under `crucible/`, resolves the branch tip, checks the remote with `push-remote.sh`, asks core's `gate-answer.sh` for the yes and checks it unused, then pushes exactly that tip as `<tip>:refs/heads/<branch>`: no hook (`core.hooksPath=/dev/null`), through dev-base's `run-timed.sh`, stopped with everything it started after `--timeout` seconds (default 60, at most 600). Then it asks `worktree-trees.sh` again, since the tree can be dropped while the push runs, and writes `push.made`. |
| `scripts/main/push-remote.sh` | The remote must be configured (`git remote get-url --push --all`). A URL naming a folder on this machine (a path, `file://`, relative to the repository) that is a repository whose git common directory is this one's is refused: a checkout, its git folder, or one of its worktrees. Other URLs (ssh, https, `<helper>::`) are not checked. |
| `scripts/lib/git-push.sh` | Shared, prefix `gp_`: the refusal lines, core, git-worktree and dev-base found by path text, the effort check, the work folder, the no-prompt environment, and the timed run through dev-base. |
| `events/push.made.jq` | Written only by `push-tree.sh`; the shape; `answer` used once. Whether `name` is a live tree is `push-tree.sh`'s question to `worktree-trees.sh`; the rule never replays the trees, reads gate events, or reads the effort's state. |
| `flow-step.json` | `git-push/push-tree`, stage `deliver`, ends with `push.made`, proposed when the human wants a tree's work on a remote |

- **The yes:** record `push-tree`, subject `<name>:<tip>`, the newest answer counting, each used once. One yes pushes one tip once; a new commit needs a new yes. A push that failed, or whose event was not written, leaves its yes unused.
- **`push.made {name, remote, commit, answer}`**: `commit` the tip pushed.
- **The lease.** Only the tree's events since its cut count. When its newest `worktree.moved` is newer than its newest `push.made` to the same remote, the push is `--force-with-lease=refs/heads/<branch>:<that push's commit>`; otherwise it is a plain push, and a remote that moved on is a rejection (exit 5), never forced.
- **Never prompting.** `GIT_TERMINAL_PROMPT=0`; an empty `GIT_ASKPASS` and `SSH_ASKPASS` (the empty value also hides `core.askPass`); `SSH_ASKPASS_REQUIRE=never` and `GCM_INTERACTIVE=never`; ssh run with `-o BatchMode=yes -o ConnectTimeout=10` after any `GIT_SSH_COMMAND` or `core.sshCommand`. Credential helpers still answer.
- **After the effort ended.** The tree list, the gate and core's writer accept any effort state, so a closed effort's tree can still go public.
- **No upstream.** The push writes nothing to the repository's config.
- **The protected names** can't come from a real cut: `worktree.cut`'s rule forces `crucible/<effort folder name>/<name>`. The check stands for a log edited by hand.

## Installed only

Both context scripts find core as a neighbour skill: they cut their own path as text (the file, `main`, `scripts`, the skill folder) to get the skills folder, and look for `crucible-context/scripts/main/context-docs.sh` there. No `..`: through a skill link, `..` resolves from the link's real target, where core is not a neighbour.

When core isn't there, they refuse in one plain line (exit 2): core's context isn't beside this skill; install first. So they run installed only, and their `--help` says so. `tracker-read.sh` needs no core, only dev-base beside it, and refuses the same way without it.

## Decided, and why

- **Jira later,** as its own piece with its own credential handling, once a real Jira task needs it. It never goes through the legacy skills.
- **Signposts instead of hows.** The `--help` is the contract; without a signpost, main wouldn't know the scripts exist and would add a live link.
- **No events.** Nothing reads a read or a copy back. The cut that seals the copy records it.

## Known limits

- Git identity: commits must be signed. An identity with no signing key, for unsigned commits, is not built; its trigger is the first human who doesn't sign commits.
- Git identity: more than 4 usable identities is refused until a real case shows up.
- Git mount: when `git apply` fails part way (a disk error) and `git apply -R` can't take the part out, the record stays and the human reverses it by hand; stderr says how.
- Git worktree: the setup plan is JSON, so a dependency folder whose name is not valid UTF-8 can't be named in it; on a file system that allows such names, its copy fails as a problem (exit 4) instead of copying it. APFS refuses such names.
- Git worktree: a catch-up that ran `--abort` and whose event write then fails is rolled back by starting the merge again; conflict resolutions the human made before the abort are lost. They were being thrown away by the abort.
- Git mount: a mount-undo whose `mount.undone` can't be written (exit 6, the lock held) has already taken the mount out, and no event is written then or on a rerun. The log then holds a mount with no undo. Undoing is the safe direction, so it is not rolled back.
- Git push: a push whose `push.made` can't be written (exit 4, or 6 for the lock) is on the remote with no event; stderr says so. With the lock, running it again with the same yes records it; a tree dropped meanwhile has no event to record.
- Dev base: a time-out stops the processes beneath the command found with `pgrep -P`; where `pgrep` is missing, only the command itself is stopped. A process that has already left the command's tree, a daemon or the child of a process that ended, is not stopped.
- Git worktree, git mount, git push: whether a tree is live is the writing script's question to `worktree-trees.sh`; the rules never replay the trees. A direct write that claims the script as its writer would pass the rule; core's guard on the writer is what stops it.

- A repository's first commit has no parent, so it has no diff to write, and the refusal then says the commit "changes no file the context may hold", which is not the reason. A note for whoever next touches the script, not a fix.
- Reading GitLab comments while logged in is not yet proven on a live host.
- GitLab comments are read in one page of at most 100 notes.
- The 500-line cut keeps the oldest lines, so a long issue loses its newest comments.
- The domain skills' names (`trackers`, `code-context`) wait on the owner. Framework skills carry the `crucible-` prefix.
