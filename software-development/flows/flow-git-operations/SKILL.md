---
name: flow-git-operations
description: The orchestrator's on-demand procedure for a VCS / GIT-OPERATIONS request — the steps the primary agent runs when the user asks to commit, push, create a branch, cut a release tag, or open/update a pull request (GitHub) or merge request (GitLab). Bind this skill when such a request fires ("commit", "commit that", "push", "branch off", "tag a release", "cut a release", "open a PR", "update the PR", "open an MR", "update the MR"), or when you are about to land changes you were asked to commit. It owns: briefing the git-operator to PLAN (read the diff, derive the atomic per-concern split un-framed by you, author each Conventional-Commit message to a file, resolve the signing identity, stage the hunks — or, for a PR/MR, draft the title/body), exposing that plan (the full commit messages or PR/MR body VERBATIM), CONSENT-GATING every commit / push / tag / PR / MR write (the orchestrator executes only on the user's explicit in-turn approval), and EXECUTING the operation itself (the orchestrator writes; the operator only proposes — a subagent cannot verify that a relayed approval is genuine consent). It does NOT define commit/branch/tag CONVENTIONS (standard-git-commit / standard-git-branch / standard-git-tag), the PR/MR-body craft (standard-git-pr, which covers both), the git MECHANICS (procedure-git-ops scripts), the PR MECHANICS (procedure-gh-pr scripts), the GitLab MR MECHANICS (procedure-glab-mr scripts), the signing-identity gate (procedure-git-identity), or the account gates (procedure-github-auth / procedure-gitlab-auth); it defines the orchestration procedure only. **Pull requests AND GitLab merge requests ARE here** — that work requires reading and understanding a diff, which is development work, not backlog authoring (the `project-manager` never touches a PR or MR).
---

# Flow: Git Operations (on-demand)

The primary agent binds this skill **only when a VCS / git-operations request fires** — the git
counterpart of the project-manager's `flow-project-management`. The rest of the time it costs
nothing (it is not loaded). Its reason to exist: a commit is a permanent signed record and a push
is public, so the *how* — plan → expose → consent → execute — is procedure, and procedure lives in
a skill, not inlined in the operating contract.

**Trigger phrases:** "Commit" / "commit that" · "Push" · "Create a branch / branch off" · "Tag a
release / cut a release" · "Open a PR / pull request" · "Update the PR" · "Open an MR / merge
request" · "Update the MR". *(A commit request is the
single most common way unreviewed work ships — "commit that" matches no build/review mode — so this
skill also owns the consent + reviewed preconditions below, not just the mechanics.)*

**What this skill owns vs. what it doesn't:**
- **Owns (here):** the plan-via-operator, exposure of the messages/PR/MR body verbatim, the three
  permissions + the consent gate, and the orchestrator EXECUTING the operation.
- **Conventions** (commit format, branch naming, SemVer tags, PR/MR-body craft) → `standard-git-commit` /
  `standard-git-branch` / `standard-git-tag` / `standard-git-pr` (the git-operator builds to them —
  and `standard-git-pr` covers a GitLab MR body too; there is deliberately no `standard-git-mr`).
- **Mechanics** (the deterministic scripts) → `procedure-git-ops` for commit/branch/push/tag,
  `procedure-gh-pr` for GitHub PR discovery/creation/editing, `procedure-glab-mr` for GitLab MR
  discovery/creation/editing. **Signing identity** → `procedure-git-identity`.
  **GitHub account** → `procedure-github-auth` (gates a push AND a PR write identically).
  **GitLab account** → `procedure-gitlab-auth` (the same gate shape for any MR write).
- **Pull requests ARE here** — opening, describing, and updating a PR is the `git-operator`'s job
  (see the Pull-Request Path below), because it requires reading and understanding the diff, which
  is development work; the `project-manager` (`flow-project-management`) never touches a PR.
- **GitLab merge requests ARE here too**, for the identical reason — see the Merge-Request Path
  below, which is the Pull-Request Path with GitLab's mechanics and account gate substituted.

---

## Step G1 — The three permissions (confirm ALL THREE before anything — they are different)

1. **Consent** — the user explicitly asked for THIS commit/push/tag in this conversation. Neither a
   review nor an identity check can supply it. **If you are unsure whether they asked — they did
   not.** (The hard invariant below.)
2. **Reviewed** — changes **you** made that `git status` shows uncommitted have been through **at
   least `flow-implementation`'s tech-pair loop** (the developer + `{tech}-reviewer` correctness
   pass — NOT necessarily a `flow-review` lens swarm, which only ever runs on a separate, explicit
   ask and is never a precondition for committing). This is the ONE state-based check surviving
   from the previous design: it does not re-run anything and costs nothing beyond asking. If you
   cannot positively recall this diff going through `flow-implementation` this session, **say so
   and ask the human explicitly** — "these changes haven't been through the tech-pair review yet;
   commit anyway, or run `flow-implementation`'s review-only variant first?" — rather than assuming
   either answer. Pre-existing dirty work you did not author is not yours to gate on; say it is
   there and leave it alone.
3. **No open gating finding** — the merged verdict is not `CHANGES_REQUIRED`. **"It has been
   reviewed" is not "it passed."** Open CRITICAL/HIGH findings do not clear a commit; they document
   one. Shipping against an ignored report is worse than shipping unreviewed — it manufactures a
   paper trail.

---

## Step G2 — Delegate to the `git-operator` to PLAN (not execute)

Dispatch the `git-operator` FIRST for the plan — it reads the diff and derives the split **un-framed
by you**, which is the whole reason the seat exists. It has NO conversation history; give it the
repo path, the branch/base, what changed and why (or "read the working-tree diff"), the ticket id,
and the operation(s) wanted. It:
- reads the diff and derives the **atomic per-concern commit split**,
- authors each **Conventional-Commit message to a FILE** (per `standard-git-commit`; a message from
  a diff can carry backticks/`$()`, so it never goes on a command line),
- **resolves and presents the signing identity** (`procedure-git-identity`),
- **stages** the intended hunks (staging *is* the atomic-split decision),
- and **reports the plan** — the split, each full message, the resolved identity.

**It PLANS and STOPS.** It does not perform the commit/push/tag — a subagent cannot verify that a
relayed approval is genuine consent, so it never executes off a relay (mirrors `flow-project-management`
P5). Do not argue with that refusal or re-relay more emphatically; it is correct.

---

## Step G3 — Expose the plan (the operator cannot reach the human — you must)

**Emit as LIVE MARKDOWN — never inside a code fence.** Relay the operator's plan as received: the
atomic split + one-line rationale, **each commit's full message (subject + body) VERBATIM** — not a
summary, not just the count and the split — and the **resolved signing identity**. A commit is a
permanent signed record; the human approves the **message**, not merely the act. The git-operator
is a subagent — it presents the messages to YOU, never to the human — so a "yes" obtained without
having shown the message that will be written does NOT satisfy the gate.

**The authored message deliberately OMITS the `Signed-off-by` trailer** — `commit.sh --signoff`
appends it from the resolved signing identity (`standard-git-commit` owns this rule). When you expose
the message, note that the landed commit will additionally carry `Signed-off-by: <resolved identity>`,
so what the human approves and what is committed reconcile.

---

## Step G4 — The commit gate (MANDATORY — before ANY commit / push / tag)

No commit, push, or tag happens without the user's **explicit approval of THIS operation, in their
own turn**, *after* G3 exposed the messages + identity.

- **Per operation, not per session** — approval to commit is not approval to push; approval of one
  commit is not approval of the next.
- **Push and tag are separately consequential** (public / immutable, hard to retract): **name the
  remote/branch** ("push to `origin/feat-x`") or the **version + SHA** so the consent is to the real
  effect, not a vague "yes".
- Approval of the *code* ("looks good", "ship it") is **not** approval to commit — ask the outward
  question explicitly.

**Collect the consent via `AskUserQuestion`** — the same structured gate `flow-implementation`'s
plan uses (`flow-implementation` §3). The full messages + identity stay in G3's live-markdown reveal *above* the
question (a commit body cannot fit a button label); the question only captures the choice + scope:
- Header **"Commit"** · question *"Approve the commit(s) above? (messages + signing identity shown)"*
- Options: **"Approve — commit only"** · **"Approve — commit + push to `origin/<branch>`"** (name the
  actual branch) · **"Request changes"** → loop to G2. (`AskUserQuestion`'s built-in **"Other"**
  also captures a free-text change.) A **tag** gets its own option naming the **version + SHA**.

The scope MUST be **named in the label** — the human clicks "…push to `origin/feat-x`", never a vague
"yes" — and that named target (remote/branch, or version+SHA) MUST be **the operator's planned/staged
target from G2**, never a value you re-derive, so the label and the operation you execute cannot
diverge. Only the selected option authorizes G5; **"Request changes" / "Other" loops back to G2**,
never to execution.

---

## Step G5 — Execute the operation (only on G4 consent) — the orchestrator writes

Once the user has explicitly approved a specific operation in their own turn, **you (the
orchestrator) execute it** — the operator *planned*; you *write*. You are the participant who holds
the user's authorization, so this is a change of *who acts*, never a lowering of the bar. **Execute
ONLY the G4-approved scope — nothing beyond it:** if the plan proposed more than the user approved
(e.g. they approved the commit but not the push), run only what was approved; anything beyond loops
back to G2 for its own gate (mirrors `flow-project-management` P5 step 3). Bind
`standard-git-commit` + `procedure-git-identity` (+ the account gate matching the remote's actual
backend for a push — `procedure-github-auth` for a GitHub remote, `procedure-gitlab-auth` for a
GitLab one; a plain `git push` targets whatever the repo's remote is, so bind whichever gate matches
it, never assume GitHub) so the same gates apply. The `procedure-git-ops` scripts are deployed
globally — invoke them **by their deployed absolute path**; you need not be their bound owner.

1. **Identity gate** — confirm the resolved signing identity the operator presented still holds
   (`procedure-git-identity`); it must agree with the committer + sign-off. A mismatch STOPS you.
2. **Stage** the intended hunks if not already staged (`git apply --cached` / `git add <path>` —
   never `git add -A`, which sweeps unrelated files).
3. **Commit** — materialize the message YOURSELF (as `flow-project-management` P5 does for a PR body):
   `Write` the message the operator authored and you exposed verbatim in G3 to a temp file via
   `mktemp` under the system temp dir — **never inside the repo** — and do NOT rely on the operator's
   preview path. Then `$HOME/.claude/skills/procedure-git-ops/scripts/commit.sh --repo …
   --message-file <that temp file>`. It commits the staged set **signed + `Signed-off-by`**, verifies
   the signature, and **fails closed** (never `--no-gpg-sign` / `--no-verify`). Re-stage the next unit
   and repeat per the split. (Committed == the message the human saw in G3 — any edit loops back
   through G2→G3→G4.)
4. **Push** (if approved) — `$HOME/.claude/skills/procedure-git-ops/scripts/push.sh --repo … --remote
   … --branch …` (refuses protected branches, detects non-fast-forward, sets upstream on first push).
5. **Tag** (only when asked AND authorized for THIS version) — the release-prep build per
   `standard-git-tag`, then `create-tag.sh` (signed annotated SemVer, refuses to re-tag).
6. **Report** what landed — SHAs / tag / push status — from the scripts' actual `GITOP_*` output,
   never a fabricated SHA or tag.

If the user asked to **change** the split or a message instead of committing, loop back to G2 (brief
the operator with the change); re-expose (G3); re-gate (G4). Match ceremony to stakes — a one-line
fix is one question, not a ritual.

---

## The Pull-Request Path (opening/updating a PR — parallel to G1–G5, its own gate)

A PR request skips G1's three commit permissions (a PR is opened *from* commits that already
exist — it is not itself a commit) and instead runs this shape: **plan → expose → consent →
execute**, identical in spirit to G2–G5, mechanics via `procedure-gh-pr` instead of `procedure-git-ops`.

1. **Delegate to the `git-operator` to PLAN the PR (not open/edit it).** Give it the repo, the
   head/base branches (**the base is an input you supply — never let the operator default Git-Flow**;
   if you don't have it, ask the human first), and what changed and why. It runs `find-pr.sh`
   (read-only — is one already open for this head?), then drafts the **title** (Conventional-Commit-style)
   and **body** (What/Why/How-to-test/risk/linked issue) per `standard-git-pr`, to a file. **It PLANS
   and STOPS** — same refusal-to-execute-off-a-relay doctrine as G2.
2. **Expose the plan verbatim** — the full drafted title + body (live markdown, never a code fence),
   and whether it's a create or an update to an existing open PR (name the PR number if so).
3. **The PR gate (MANDATORY, before ANY open/edit).** Same shape as G4: **consent, per operation, not
   per session** — approving the commits that will go up is not approving the PR; naming the exact
   head→base (a create) or PR number (an edit) in the gate's option label, never a vague "yes".
   Collect via `AskUserQuestion`: header **"Pull Request"** · question *"Approve this PR? (title +
   body shown above)"* · options **"Approve — open the PR (`head` → `base`)"** / **"Approve — update
   PR #N"** (name it) · **"Request changes"** → loop to step 1.
4. **Execute (only on step-3 consent) — the orchestrator writes.** Run the **GitHub-account gate**
   first (`procedure-github-auth` — the same gate a push already needs; one confirmation covers a batch
   of writes in the same turn). Materialize the approved title/body **yourself** to a fresh `mktemp`
   file outside the repo (never reuse the operator's preview path) and run, by deployed path:
   `create-pr.sh --repo … --head … --base … --title "…" --body-file <temp file>` (refuses a
   duplicate — if one already exists, update instead) or `update-pr.sh --repo … --pr N --body-file
   <temp file> …` (**the body is REPLACED, not appended** — this was already disclosed at step 2).
   **Report** the PR number/URL from the script's actual output — never a fabricated one.

If the user asked to **change** the title/body instead of approving, loop back to step 1; re-expose;
re-gate. This path never runs G1 — a PR write is not a commit and carries no "reviewed"/"no open
gating finding" precondition of its own (the commits it points at already cleared those, if any).

---

## The Merge-Request Path (opening/updating a GitLab MR — parallel to the PR Path, its own gate)

A GitLab MR request runs the **identical** shape as the Pull-Request Path above — **plan → expose →
consent → execute**, skipping G1's three commit permissions (an MR is opened *from* commits that
already exist) — with GitLab's mechanics and account gate substituted: `procedure-glab-mr` instead of
`procedure-gh-pr`, `procedure-gitlab-auth` instead of `procedure-github-auth`. The body craft is the
**same `standard-git-pr`** (What/Why/How-to-test/risk/linked issue is tech-agnostic; there is no
separate `standard-git-mr`). **Which path applies is resolved from the repo's remote, not asked as a
separate question** — the same way "open a PR" vs. "open an MR" already disambiguates by trigger
wording; if a repo genuinely carries both a GitHub and a GitLab remote, ask which one rather than
guessing (this lives in the `git-operator`'s own body today — see its "GitLab specifics" paragraph —
not duplicated here as a second copy of the same rule).

1. **Delegate to the `git-operator` to PLAN the MR (not open/edit it).** Give it the repo, the
   source/target branches (**the target is an input you supply — never let the operator default
   Git-Flow**; if you don't have it, ask the human first), and what changed and why. It runs
   `find-mr.sh --repo … --source-branch … --confirmed-host <host>` (read-only — is one already open
   for this source branch? — the host is the one `procedure-gitlab-auth` already confirmed; see step
   4's account gate for where that comes from), then drafts the **title** (Conventional-Commit-style)
   and **description** per `standard-git-pr`, to a file. **It PLANS and STOPS** — same
   refusal-to-execute-off-a-relay doctrine as G2.
2. **Expose the plan verbatim** — the full drafted title + description (live markdown, never a code
   fence), and whether it's a create or an update to an existing open MR (name the MR's **iid** — the
   `!123` number — if so).
3. **The MR gate (MANDATORY, before ANY open/edit).** Same shape as G4: **consent, per operation, not
   per session** — approving the commits that will go up is not approving the MR; naming the exact
   source→target (a create) or MR iid (an edit) in the gate's option label, never a vague "yes".
   Collect via `AskUserQuestion`: header **"Merge Request"** · question *"Approve this MR? (title +
   description shown above)"* · options **"Approve — open the MR (`source` → `target`)"** / **"Approve
   — update MR !N"** (name it) · **"Request changes"** → loop to step 1.
4. **Execute (only on step-3 consent) — the orchestrator writes.** Run the **GitLab-account gate**
   first (`procedure-gitlab-auth` — present the resolved account and get the user's confirmation; if
   several instances are configured, resolve with `glab-auth-status.sh --hostname HOST` before asking,
   never guess which is active). **The confirmed host from this gate is `--confirmed-host` below —
   every `find-mr.sh`/`update-mr.sh` call carries it; there is no optional-but-recommended middle
   state.** Materialize the approved title/description **yourself** to a fresh `mktemp` file outside
   the repo (never reuse the operator's preview path) and run, by deployed path:
   `create-mr.sh --repo … --repo-dir <the repo's local working-tree path> --source-branch …
   --target-branch … --title "…" --description-file <temp file>` (refuses a duplicate — if one
   already exists, update instead) or `update-mr.sh --repo … --mr N --confirmed-host <host>
   --description-file <temp file> …` (**the description is REPLACED, not appended** — this was
   already disclosed at step 2). `--repo-dir` is not new information for you to derive: it is the
   **same local repo you are already operating in** for the commits and the push — `glab mr create`
   has no host-selection flag and resolves the GitLab host from the invoking directory's git remotes,
   so it must run from inside that checkout. `update-mr.sh` needs no `--repo-dir` — it has no local
   checkout to anchor it, which is exactly why it instead REQUIRES `--confirmed-host` (a usage error
   without it): the host you just confirmed at the top of this step. **Report** the MR iid/URL from
   the script's actual output — never a fabricated one.

Three GitLab-shaped details that differ from the PR path and must not be smoothed over: the flags
speak GitLab (`--source-branch`/`--target-branch`, not head/base), the number is GitLab's per-project
**iid**, and a project path may carry **nested subgroups** (`group/subgroup/project`) — relay it
verbatim rather than "correcting" it to an `owner/repo` shape.

If the user asked to **change** the title/description instead of approving, loop back to step 1;
re-expose; re-gate. Like the PR path, this one never runs G1.

---

## Termination

This flow does not auto-continue. When the approved operation(s) have landed, **stop**. A later "now
push it", "now tag a release", "now open the PR", or "now open the MR" is a **new invocation** with
its own gate — never an automatic next step. A new review pass your own push (or PR/MR) triggered is
likewise a new invocation.

---

## Invariants (NEVER break)

- **NEVER commit / push / tag without the user's explicit in-turn consent for THAT operation** —
  not the operator, not you off a relay. If unsure whether they asked, they did not. (The hardest
  rule; stated in full in CLAUDE.md §1.)
- **Expose the full commit messages verbatim before consent** — the git-operator is a subagent and
  cannot reach the human; a "yes" without the message shown does not count (G3).
- **The orchestrator executes; the operator only plans** (G2/G5) — a subagent cannot verify a
  relayed approval, so it never executes off a relay, and routing an approved commit *back* to it
  would deadlock. Same doctrine as `flow-project-management` P5.
- **Reviewed + no open gating finding** before committing your own changes (G1).
- **Identity confirmed + signature fail-closed** — never commit under an unconfirmed/mismatched
  identity; `commit.sh` enforces the signature (G5).
- **Push / tag are separately consequential** — name the target/version; per-operation consent (G4).
- **Never fabricate** a SHA, tag, or push status — report only what a script returned (G5).
- **A PR *or MR* write follows the same plan/expose/consent/execute shape as a commit** — the
  git-operator proposes; the orchestrator executes; a relayed "the user approved, open it" is never
  consent (Pull-Request Path / Merge-Request Path).
- **Never let the git-operator default the PR's base *or the MR's target* branch** — it is an input
  from the delegation; ask if missing (Pull-Request Path / Merge-Request Path).

---
*Procedure Version: 1.2 — the on-demand VCS / git-operations workflow, extracted from CLAUDE.md §1's VCS block so the operating contract carries only the trigger + the invariant checklist. The git counterpart of `flow-project-management`. Conventions live in `standard-git-commit` / `-branch` / `-tag` / `-pr` (the last covering GitLab MR bodies too); mechanics in `procedure-git-ops` / `procedure-gh-pr` / `procedure-glab-mr`; the signing identity in `procedure-git-identity`; the accounts in `procedure-github-auth` / `procedure-gitlab-auth`. **Pull requests belong here** (moved from the project-manager — PR work is development work, not backlog authoring; see the Pull-Request Path), **and so do GitLab merge requests** (see the Merge-Request Path, added in 1.2). This skill is the orchestration procedure only.*
