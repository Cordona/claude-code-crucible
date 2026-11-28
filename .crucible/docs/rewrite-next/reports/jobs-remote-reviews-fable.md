# Remote reviews on the new chain: Fable's design review (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `specs/jobs-remote-reviews.md`. From earlier today: the job view, `jobs_finish`, the kind files, the cut's `from` forms.

**Not done:** nothing was run. I did not read `events-view.sh`, `tracker-read.sh`, the reviewer's facts scripts, or `specs/jobs-HANDOFF.md`.

## Verdict

**The design is right: approve, with four changes before it is built.** The inputs become facts, the kinds move with no new branch in `jobs/track`, and one kind-file word changes for a fact resolve must check. That is the line we set.

| Change | Section |
|---|---|
| The live reads on the owner's logins need the owner's own yes, and no private text goes into the repo | 1 |
| Three new JSON shapes go to the owner first; each field of the threads file names its reader | 2 |
| For a foreign review, resolve fills the tree's cut from the change; main doesn't type the sha | 3 |
| The pinned reuse is sound; say what it is in one place | 4 |

## 1. The validation, before anything else

**The live reads use the owner's `glab` and `gh` logins.** They are read-only, and they are still calls made as the owner, on merge requests that belong to another project. A standing rule in my notes: no call on the owner's tracker login in any run unless the owner asked for that run. "If Fable approves, build it, then validate live" may cover it; I can't tell, and my approval is not that yes. Before the live reads, the owner says yes to: which merge requests, on which login, read-only.

**No private text in the repo.** The stub replies are to be "captured from the live reads, secrets and private text replaced". Replies captured from a private project's merge requests should not be the source of committed fixtures at all, scrubbed or not: scrubbing misses things, and the framework is not to carry a company's material. Capture fixtures from the public GitHub pull requests, and write the GitLab ones by hand from the shape the live read shows.

## 2. Three shapes for the owner; the threads file is the one to trim

**`remote-change.fetched`, `remote-review.fetched` and the threads file are new JSON shapes.** The owner approves shapes before they are built.

**The two events are lean.** Untrusted text stays out of them, in the pinned file. Good.

**The threads file is where a specific field can bite.** It goes from `{id, source}` to twelve fields. Each one should name who reads it: the reviewer judging the comment, or a stamp. From the draft I can place `id`, `source`, `path`, `line`, `commit`, `comments.body`, `comments.role`. I can't place `kind` (a line thread already shows by having a path), `at`, or `outdated` (the `commit` says the same thing more exactly). Keep what has a reader; the rest can come back when a run shows the reviewer missing it.

## 3. `range`, and the cut for a foreign review

**`range` as "where it comes from": agreed.** It is a new value for a new fact resolve checks, and `review.json` changes to `"tree"`. A range on a cut tree is the honest shape for a foreign change.

**One simplification.** As drafted, main writes the cut by hand (`repo` and `from: "ref:<the change's head>"`), and resolve then checks both against the change. Everything in that cut is already in the event main named. So let resolve fill it: main gives `change: 17`, and resolve writes the tree's cut and the range from it. One check fewer, and no sha typed by main. The last live run's fault 2 was exactly a `from` that main worded differently from the cut script.

**Confirm one thing:** `worktree-cut.sh` takes a full sha after `ref:`. The fetch leaves no branch, so the sha is the only name the commit has.

## 4. Pinned like a report: sound

**Mechanically it holds.** The tamper check covers any event with a pinned file, the agents reach both files through `refs`, and nothing is added to `jobs/track`. A fetched file can't be mistaken for a hand-in: a hand-in also names its job, and these events don't.

**The stretch is only in the name.** `report` now means "a pinned file", of which an agent's report is one sort. Don't rename it; that would touch every submission rule for no gain. Say it once, where `events-view.sh` describes what it joins, so the next reader doesn't take `reports/remote-change/17.json` for something an agent wrote.

## 5. Smaller points

- **The safe-link check shared with `trackers/`.** If `remotes/` sources it from `trackers/`, one floating piece depends on another; if it copies it, there are two. It belongs where the timeout helper already is, in dev-base.
- **The fetch writes `FETCH_HEAD` in the human's repo.** Harmless, but the toolbelt's line is that it never touches the human's refs. Fetch without writing it if the installed git allows, or say in the script's contract that it does.
- **Two hosts at once: right.** The common shape is drawn from two real cases, not guessed from one.
- **No gate for a fetch: agreed.** Nothing changes on the remote, and it matches how tracker reads work.
- **Posting back left out: right.** That is the write, and it gets its own gated piece.
- **`remotes/SKILL.md`** comes to me before a session uses it.

## 6. Addendum: `--bot NAME` on GitLab

**Agreed, and it makes the design smaller if taken all the way.** GitLab can't say who is a bot, so the human says it and the event records it (`bots: [...]`). That is a fact with a source, which is better than a guess from a username.

**Three things with it:**
1. **Drop the guessing on GitLab.** With `--bot`, the per-author `users/:id` read and the `project_N_bot` name patterns have no job left. Keep GitHub's own answer (`__typename`), which the host does give.
2. **Optional, with a plain default.** No `--bot` means every GitLab author is read as human. Then nothing forces a question on the human; main asks only when the human mentions an AI reviewer or the threads make it obvious. "Main asks once" as a rule is one more line of prose; the default removes the need for it.
3. **A second fetch of the same change takes the first one's bots** unless told otherwise. Otherwise main has to carry the names from one fetch to the next, which is a slip a script can cover.

**One question about the check itself.** The addendum rests on a live read of GitLab. Section 1 asked for the owner's own yes before any read on the owner's login. If that yes was given, say so in the spec; if the read was made before it, the owner should be told.

## 7. For the owner

1. **The live reads on your logins** (section 1): yes or no, and on which merge requests.
2. **The three shapes** (section 2), with the threads file trimmed to fields that have a reader.
