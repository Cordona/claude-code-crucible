---
name: flow-git-operations
description: "The orchestrator's on-demand procedure for a VCS (version control system) / git-operations request: commit, push, branch, tag, or open/update a pull request (GitHub) or merge request (GitLab). Bind when such a request fires, or before landing changes the user asked to commit. Owns briefing the git-operator to plan, exposing the plan verbatim, consent-gating every write, and executing it. Does NOT define commit/branch/tag/PR conventions, git/PR/MR mechanics, the signing-identity gate, or account gates — those are separate skills this one binds. Unlike `flow-project-management`, PR/MR work belongs here, never with the project-manager."
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
  **GitHub account** → `procedure-github-auth` (gates a PR write; a plain `git push` uses git's own
  remote credentials, not `gh auth` state, so this gate has nothing to contribute there).
  **GitLab account** → `procedure-gitlab-auth` (the same gate shape for any MR write — and, as a
  pre-flight, for any commit/push on a GitLab remote too, since the identity gate needs its
  confirmed host to produce a definite platform-verified-email answer at all).
- **Pull requests ARE here** — AUTHORING a PR (finding it read-only, drafting the title/body) is the
  `git-operator`'s job; the orchestrator opens and updates it (see the Pull-Request Path's step 4
  below) — because authoring requires reading and understanding the diff, which is development work;
  the `project-manager` (`flow-project-management`) never touches a PR.
- **GitLab merge requests ARE here too**, for the identical reason — see the Merge-Request Path
  below, which is the Pull-Request Path with GitLab's mechanics and account gate substituted.

---

## Step G1 — The three permissions (confirm ALL THREE before anything — they are different)

1. **Consent** — the user explicitly asked for THIS commit/push/tag in this conversation. Neither a
   review nor an identity check can supply it. **If you are unsure whether they asked — they did
   not.** (The hard invariant below.)
2. **Reviewed** — changes **you** made that `git status` shows uncommitted have cleared
   `flow-implementation`'s correctness floor for this diff (NOT necessarily a `flow-review` lens
   swarm, which only ever runs on a separate, explicit ask and is never a precondition for
   committing). **This is NOT the same question as "has this effort touched `flow-implementation` at
   all."** `flow-implementation`'s Validate-First path can be live-validated and fully
   `flow-testing`-covered while its deferred `{tech}-reviewer` pass (that flow's §4d) has genuinely
   not run yet — that diff has NOT cleared the floor, no matter how much scrutiny the live validation
   and the test suite gave it. What "cleared" means depends on which of `flow-implementation`'s two
   correctness-floor mechanisms applies to this diff:
   - **A stack with a `{tech}-reviewer`** (Validate-First or Pair-First) — cleared only once that
     reviewer's own gating findings have closed for this diff.
   - **No `{tech}-reviewer` exists for the stack** (`flow-implementation` §6 Direct implementation,
     or any framework-prose change — `CLAUDE.md`, a `SKILL.md`, an agent definition) — cleared once
     that flow's **execution-test** floor (§2, and §6's Direct implementation step 3, there) has run against this diff and found nothing
     it couldn't comply with. Do not read "no reviewer exists" as "this precondition doesn't apply" —
     it applies via this branch instead.

   **A single diff spanning BOTH classes clears only when EACH class has cleared its own mechanism** —
   never one branch standing in for the whole diff. A working tree mixing reviewer-backed code with
   framework-prose changes (a common shape in this repo) does not satisfy this precondition just
   because the prose half passed an execution test; the code half still needs its own `{tech}-reviewer`
   pass closed. **This per-class check is asked here at G1, before `git-operator`'s atomic split (G2)
   exists, and CANNOT be fully answered yet if the split is still unknown — re-ask it concretely at G3,
   once the actual split is in hand:** check each real commit's own class against G1's answer before
   exposing the plan, and do not let one commit's cleared floor vouch for another's.

   This is the ONE state-based check in the framework: it does not re-run anything
   and costs nothing beyond asking. If you cannot positively recall the applicable floor having
   actually closed for this diff, **say so and ask the human explicitly, naming which floor is
   outstanding** — for example: *"these changes haven't cleared the `{tech}-reviewer` pass yet — they're
   live-validated and tested, but the deferred reviewer hasn't closed; commit anyway, or finish that
   pass first?"*, or *"these changes haven't had an execution test run against them yet; commit
   anyway, or run one first?"* — rather than assuming either answer. **On a mixed-class diff, offer the
   per-class split explicitly rather than forcing an all-or-nothing answer** — e.g. *"the code half has
   cleared its `{tech}-reviewer` pass; the framework-prose half hasn't had an execution test yet. Commit
   just the code now and hold the prose changes, or run the execution test first and commit both
   together?"* Pre-existing dirty work you did not author is not yours to gate on; say it is there and
   leave it alone.
3. **No open gating finding** — the merged verdict is not `CHANGES_REQUIRED`. **"It has been
   reviewed" is not "it passed."** Open CRITICAL/HIGH findings do not clear a commit; they document
   one. Shipping against an ignored report is worse than shipping unreviewed — it manufactures a
   paper trail.

---

## Step G2 — Delegate to the `git-operator` to PLAN (not execute)

**Pre-flight, on a GitLab remote specifically: bind `procedure-gitlab-auth` and try to confirm the host
BEFORE this dispatch, even for a plain commit with no MR involved.** `procedure-git-identity`'s
`resolve-identity.sh --gitlab` is CAPPED at `unknown`/`skipped` — it can never report a definite
`verified`/`unverified` — unless it's pinned with `--gitlab-host HOST` from this gate; without this
pre-flight, every GitLab commit's platform-verified-email check fails to `unknown` by construction,
not by circumstance, defeating the check silently. **Unlike the Merge-Request Path's pre-flight, an
unconfirmable host here does NOT halt** — a commit needs no `glab` call at all, so degrade to running
`resolve-identity.sh --gitlab` unpinned and report the resulting `unknown`, per `procedure-git-identity`'s
own fail-open contract (an unrunnable check is a notice, never a block). The Merge-Request Path's HALT
is specific to `find-mr.sh` hard-requiring `--confirmed-host` — that requirement doesn't exist here.
**This confirmation is amortized across the whole turn, same as any other account gate** — if you already
confirmed the GitLab host earlier in this turn (for an MR, or an earlier commit) and the active account
hasn't changed, reuse it; do not re-ask. Thread the confirmed host into the
operator's brief below so it can pass `--gitlab-host` to `resolve-identity.sh` from the start — or, if it
could not be confirmed, say so and pass none (never an unconfirmed host), so the operator runs it unpinned.

Dispatch the `git-operator` FIRST for the plan — it reads the diff and derives the split **un-framed
by you**, which is the whole reason the seat exists. It has NO conversation history; give it the
repo path, the branch/base, what changed and why (or "read the working-tree diff"), the ticket id,
the operation(s) wanted, **the pre-flight-confirmed GitLab host if the remote is GitLab**, **and any
developer-reported "deferred to the commit/PR message" rationale from the build report's Key
decisions field** (`build-core`/`build-report-standards`) — that content has no other path into the
commit message, so it must be relayed here explicitly, not assumed. It:
- reads the diff and derives the **atomic per-concern commit split**,
- authors each **Conventional-Commit message to a FILE** (per `standard-git-commit`; a message from
  a diff can carry backticks/`$()`, so it never goes on a command line),
- **resolves and presents the signing identity** (`procedure-git-identity`),
- **stages the first unit's** intended hunks (staging *is* the atomic-split decision) and reports a per-unit staging artifact for any further unit,
- and **reports the plan** — the split, each full message, the resolved identity, **and, for an
  N-commit split, a per-unit staging artifact (a hunk-filtered patch or explicit path list for each
  unit beyond the first)** — the index holds only one unit at a time, so units 2..N must be
  re-stageable from something you actually have, not re-derived by guessing hunk boundaries the
  operator already decided un-framed by you.

**It PLANS and STOPS.** It does not perform the commit/push/tag — a subagent cannot verify that a
relayed approval is genuine consent, so it never executes off a relay (mirrors `flow-project-management`
P5). Do not argue with that refusal or re-relay more emphatically; it is correct.

---

## Step G3 — Expose the plan (the operator cannot reach the human — you must)

**Before relaying anything: re-check G1's "Reviewed" permission against the ACTUAL split you now
have.** G1 could only answer that question by class (code vs. framework-prose) because the atomic
split didn't exist yet; G2 just produced the real commit boundaries. For each commit in the plan,
identify which class its own changed files fall into and confirm THAT class's mechanism has closed
for THAT commit's own files — not for the diff as a whole. A commit whose files turn out to mix both
classes (the operator's split doesn't guarantee single-class commits) needs both mechanisms closed
before it clears. If any commit fails this per-commit check, say so now and hold that commit out of
the batch you present for consent — do not let a diff-wide "reviewed" answer from G1 wave through a
commit whose actual files never cleared their class's floor.

**Emit as LIVE MARKDOWN — never inside a code fence.** Relay the operator's plan as received: the
atomic split + one-line rationale, **each commit's full message (subject + body) VERBATIM** — not a
summary, not just the count and the split — and the **resolved signing identity, rendered from
`procedure-git-identity`'s own fixed report template, verbatim.** A commit is a permanent signed
record; the human approves the **message**, not merely the act. The git-operator is a subagent — it
presents the messages to YOU, never to the human — so a "yes" obtained without having shown the
message that will be written does NOT satisfy the gate.

**If any platform status in that template came back `unknown`, relay its `{platform_unknown_notice}`
prose sentence too, never only the table's ❓ glyph.** That sentence is the one element guarding a
fail-open — the commit is not blocked by an `unknown` status and the reconciliation note will still
read "consistent", so the glyph alone is too quiet to be the sole notice; the human needs the actual
sentence naming what went unchecked and the script's remedy, verbatim.

**The authored message deliberately OMITS the `Signed-off-by` trailer** — `commit.sh`'s internal
`git commit --signoff` appends it from the resolved signing identity (`standard-git-commit` owns this
rule). When you expose the message, note that the landed commit will additionally carry
`Signed-off-by: <resolved identity>`, so what the human approves and what is committed reconcile.

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

**This gate template is scoped to a request that includes a commit** (optionally bundled with a push
and/or a tag on the just-made commit) — **a tag-only request, with no new commit involved, does NOT
run G1–G4 at all; it runs its own Tag Path below**, whose header/question are tag-shaped from the
start rather than reusing this commit-framed wording.

**Collect the consent via `AskUserQuestion`** — the same structured gate `flow-implementation`'s
plan uses (`flow-implementation` §3). The full messages + identity stay in G3's live-markdown reveal *above* the
question (a commit body cannot fit a button label); the question only captures the choice + scope:
- Header **"Commit"** · question *"Approve the commit(s) above? (messages + signing identity shown)"*
- Options: **"Approve — commit only"** · **"Approve — commit + push to `origin/<branch>`"** (name the
  actual branch) · **"Request changes"** → loop to G2. (`AskUserQuestion`'s built-in **"Other"**
  also captures a free-text change.) A **tag that follows this commit** (same request, e.g. "commit
  and tag this as a release") gets its own option naming the **version + SHA**.
  **This question supersedes the identity report's own trailing "Reply yes to proceed, or switch to
  choose another" line (`procedure-git-identity`) — a "switch" answer is a request-changes shape,
  not a fifth option here: re-brief the `git-operator` to run `procedure-git-identity`'s own step 4
  (`list-identities.sh` → `switch-identity.sh` → re-run `resolve-identity.sh`), then take its
  re-planned output back through G2→G3→G4 for a re-presented commit under the corrected identity.**

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
`standard-git-commit` + `procedure-git-identity`. A plain `git push` uses git's own remote
credentials, not an account gate — there is nothing for `procedure-github-auth` to contribute on a
GitHub remote. **On a GitLab remote, `procedure-gitlab-auth`'s confirmed host is still needed** —
not for the push itself, but because `procedure-git-identity`'s `--gitlab-host` requires it to
produce a definite platform-verified-email answer; **this CONSUMES the host G2's own pre-flight
already confirmed (or reuses any confirmation from earlier in the turn); it is not a fresh
bind unless the active account could have changed since**. The `procedure-git-ops` scripts are deployed
globally — invoke them **by their deployed absolute path**; you need not be their bound owner.

1. **Identity gate** — confirm the resolved signing identity the operator presented still holds
   (`procedure-git-identity`); it must agree with the committer + sign-off. A mismatch STOPS you.
2. **Stage** the intended hunks if not already staged (`git apply --cached` / `git add <path>` —
   never `git add -A`, which sweeps unrelated files).
3. **Commit** — materialize the message YOURSELF (as `flow-project-management` P5 does for an issue body):
   `Write` the message the operator authored and you exposed verbatim in G3 to a temp file via
   `mktemp` under the system temp dir — **never inside the repo** — and do NOT rely on the operator's
   preview path. Then `$HOME/.claude/skills/procedure-git-ops/scripts/commit.sh --repo …
   --message-file <that temp file>`, then remove the temp file once `commit.sh` has consumed it. It
   commits the staged set **signed + `Signed-off-by`**, verifies
   the signature, and **fails closed** (never `--no-gpg-sign` / `--no-verify`). For unit 2..N, apply
   G2's per-unit staging artifact (the hunk-filtered patch or path list it reported) — never re-derive
   hunk boundaries yourself — then repeat this step per the split. (Committed == the message the
   human saw in G3 — any edit loops back through G2→G3→G4.)
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

## The Branch Path (creating a branch — lighter than G1–G5, still gated)

Creating a branch is reversible and low-stakes compared to a commit/push/tag (a stray local branch
costs nothing; `create-branch.sh` refuses to overwrite an existing one) — but it is still a write, so
it still gets a plan + consent, just proportionate ceremony, not the full G1 permissions (a branch
carries no "reviewed"/"no open gating finding" precondition of its own — those attach to what gets
*committed* on it, not to the branch's existence).

1. **Delegate to the `git-operator` to PLAN the branch (not create it)** — the repo, the base branch
   to branch FROM (an input you supply — never let the operator default it; **if you don't have it,
   ask the human first**, same clause the PR/MR paths use for their base/target), and the change type
   + ticket id + a short description. The ticket id is required too — **if you don't have one, ask the
   human first; never let the operator invent one**. Pass which tracker issued it too (its case depends on
   that — `standard-git-branch`); if you don't know, ask the human. `create-branch.sh` builds the name itself as `TYPE/TICKET-DESC`
   (e.g. `feat/1-token-refresh`) — the operator proposes the type/ticket/desc parts per
   `standard-git-branch`'s convention, it does not invent a free-form name. **It PLANS and STOPS** —
   same doctrine as G2.
2. **Expose the proposed type/ticket/desc, the resulting branch name, and the base branch** (live
   markdown, never a code fence).
3. **The branch gate (MANDATORY, before ANY creation).** Collect via `AskUserQuestion`: header
   **"Branch"** · question *"Create branch `<name>` from `<base>`?"* (name both concretely) ·
   options **"Approve"** · **"Request changes"** → loop to step 1.
4. **Execute (only on step-3 consent) — the orchestrator writes.** Run, by deployed path:
   `$HOME/.claude/skills/procedure-git-ops/scripts/create-branch.sh --repo … --type … --ticket …
   --desc … --base …`. It refuses to overwrite an existing branch of the same name (a no-op, not an
   error), refuses a branch whose name differs only in letter case (exit 1 — hand it back to the
   human), and checks the built name's characters as a backstop, not the full naming convention. **It creates the branch ONLY —
   it never checks it out; the current branch is unchanged after this step.** If the intent was to
   switch onto it (e.g. "branch off and commit this"), that's a separate, explicit `git checkout`/
   `git switch` you confirm before G5 runs — never assume a just-created branch is the one G5 will
   commit onto; committing onto the wrong (possibly protected) branch is exactly the mistake this
   disclosure exists to prevent. **Report** the branch from the script's own output (`GITOP_BRANCH`) — never a
   fabricated name. `GITOP_BRANCH` is printed on a no-op too, so key on `GITOP_CREATED`, never on stderr
   text: when it is `false`, the branch already existed — it was NOT created and `--base` was NOT
   checked, so it may sit on a different base; say so rather than reporting it as created from `--base`.

If the user asked to change the name/base instead of approving, loop back to step 1; re-expose;
re-gate. This path never runs G1.

---

## The Tag Path (tagging an already-landed commit — no new commit involved, its own gate)

A **tag-only request** ("tag current `main` as `v1.2.0`", "cut a release tag for this SHA") has no
diff to review and no commit to author — the commit being tagged already cleared its own G1 when IT
was committed. Reusing G1–G4's commit-shaped permissions and gate template here would ask the wrong
questions (there is no message to expose, no "reviewed" precondition to re-litigate). This path is
the tag counterpart of the Branch Path above: lighter than G1–G5, still fully gated.

1. **Delegate to the `git-operator` to PLAN the tag (not create it).** Give it the repo, the target
   **SHA** (or a ref you resolve to one — never let the operator guess "current HEAD" silently), and
   the intended **version** (core SemVer, `vX.Y.Z` or `X.Y.Z` — `create-tag.sh`'s own validated
   shape). It authors the annotated tag message to a **file** (same injection-safety rule as a commit
   message — `create-tag.sh` has no `-m` passthrough either) per `standard-git-tag`, confirms
   `standard-git-tag`'s release-prep build succeeded for that SHA and it is not a re-tag of an
   already-published version, and **resolves the signing identity**
   (`procedure-git-identity`). **It PLANS and STOPS** — same doctrine as G2.
2. **Expose the version, the target SHA, the full tag message verbatim, and the resolved signing
   identity** (live markdown, never a code fence) — the human approves the message, same duty as G3.
3. **The tag gate (MANDATORY, before ANY tag creation).** Collect via `AskUserQuestion`: header
   **"Tag"** · question *"Create tag `<version>` at `<SHA>`? (message + signing identity shown)"*
   (name both concretely — never a bare "yes") · options **"Approve"** · **"Request changes"** → loop
   to step 1.
4. **Execute (only on step-3 consent) — the orchestrator writes.** Write the exposed message to a
   temp file via `mktemp` (never inside the repo), then
   `$HOME/.claude/skills/procedure-git-ops/scripts/create-tag.sh --repo … --version … --sha …
   --message-file <that temp file>`, then remove the temp file. It refuses outright to re-tag an
   existing version and fail-closed verifies the signature. **Report** the tag actually created
   (`GITOP_TAG`) from the script's own output — never a fabricated version or SHA.

If the user asked to change the version/SHA/message instead of approving, loop back to step 1;
re-expose; re-gate. **This path never runs G1 or G2's commit-split logic** — there is no diff and no
atomic split to derive. A request that bundles a NEW commit with a tag ("commit this and tag it
`v1.2.0`") is NOT this path — it runs G1–G5 with the tag folded into G4's own bundled option (see
G4 above), since G5 step 5 executes that tag immediately after the commit it belongs to.

---

## The Pull-Request Path (opening/updating a PR — parallel to G1–G5, its own gate)

A PR request skips G1's three commit permissions (a PR is opened *from* commits that already
exist — it is not itself a commit) and instead runs this shape: **plan → expose → consent →
execute**, identical in spirit to G2–G5, mechanics via `procedure-gh-pr` instead of `procedure-git-ops`.

1. **Delegate to the `git-operator` to PLAN the PR (not open/edit it).** Give it the repo, the
   head/base branches (**the base is an input you supply — never let the operator default Git-Flow**;
   if you don't have it, ask the human first), what changed and why, **and any developer-reported
   "deferred to the commit/PR message" rationale from the build report's Key decisions field**
   (same input as G2 — the commits it was meant for may already be landed, so the PR body is its
   only remaining destination). It runs `find-pr.sh`
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
   first (`procedure-github-auth`; one confirmation covers a batch of writes in the same turn —
   re-affirm if the active account could have changed). Materialize the
   approved title/body **yourself** to a fresh `mktemp`
   file outside the repo (never reuse the operator's preview path) and run, by deployed path:
   `create-pr.sh --repo … --head … --base … --title "…" --body-file <temp file>` (refuses a
   duplicate — if one already exists, update instead) or `update-pr.sh --repo … --pr N --body-file
   <temp file> …` (**the body is REPLACED, not appended** — this was already disclosed at step 2).
   Remove the temp file once the script has consumed it. **Report** the PR number/URL from the
   script's actual output — never a fabricated one.

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
guessing (this lives in the `git-operator`'s own body today — see its "Pull requests / merge requests"
paragraph — not duplicated here as a second copy of the same rule).

**Pre-flight (before step 1): bind `procedure-gitlab-auth` and confirm the host** — **reuse G2's own
pre-flight confirmation if this turn already ran one and the active account hasn't changed; do not
re-ask** (the same amortization rule any account gate gets within one turn). `find-mr.sh` (step 1)
REQUIRES `--confirmed-host` — a subagent cannot obtain a human's account confirmation itself, so the
host must already be confirmed by the time the `git-operator` is dispatched to plan, not first
surfaced at step 4's execute-time account gate. Confirm it here (or reuse), and thread that same
confirmed host through step 1's `find-mr.sh` call and step 4's `update-mr.sh` call — never re-derive
or re-ask mid-path. If several GitLab instances are configured, resolve with `glab-auth-status.sh
--hostname HOST` before asking, never guess which is active. **Unlike G2's plain-commit pre-flight
(which degrades to `unknown` on an unconfirmable host), HALT here if the gate cannot confirm a host at
all** — do not proceed into step 1 unpinned, because `find-mr.sh` has no fail-open path the way a bare
commit does.

1. **Delegate to the `git-operator` to PLAN the MR (not open/edit it).** Give it the repo, the
   source/target branches (**the target is an input you supply — never let the operator default
   Git-Flow**; if you don't have it, ask the human first), what changed and why, **and any
   developer-reported "deferred to the commit/PR message" rationale from the build report's Key
   decisions field** (same input as G2 and the Pull-Request Path — the commits it was meant for may
   already be landed, so the MR description is its only remaining destination). It runs
   `find-mr.sh --repo … --source-branch … --confirmed-host <host>` (read-only — is one already open
   for this source branch? — the host is the one the pre-flight step above already confirmed), then
   drafts the **title** (Conventional-Commit-style) and **description** per `standard-git-pr`, to a
   file. **It PLANS and STOPS** — same refusal-to-execute-off-a-relay doctrine as G2.
2. **Expose the plan verbatim** — the full drafted title + description (live markdown, never a code
   fence), and whether it's a create or an update to an existing open MR (name the MR's **iid** — the
   `!123` number — if so).
3. **The MR gate (MANDATORY, before ANY open/edit).** Same shape as G4: **consent, per operation, not
   per session** — approving the commits that will go up is not approving the MR; naming the exact
   source→target (a create) or MR iid (an edit) in the gate's option label, never a vague "yes".
   Collect via `AskUserQuestion`: header **"Merge Request"** · question *"Approve this MR? (title +
   description shown above)"* · options **"Approve — open the MR (`source` → `target`)"** / **"Approve
   — update MR !N"** (name it) · **"Request changes"** → loop to step 1.
4. **Execute (only on step-3 consent) — the orchestrator writes.** The **GitLab-account gate**
   (`procedure-gitlab-auth`) was already bound and its host confirmed in the pre-flight step above,
   before `git-operator` was even dispatched — this step consumes that confirmed host, it does not
   re-bind the gate or re-ask. **That confirmed host is `--confirmed-host` below — every
   `find-mr.sh`/`update-mr.sh` call carries it; there is no optional-but-recommended middle state.**
   Materialize the approved title/description **yourself** to a fresh `mktemp` file outside
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
   without it): the host you just confirmed at the top of this step. Remove the temp file once the
   script has consumed it. **Report** the MR iid/URL from the script's actual output — never a
   fabricated one.

Three GitLab-shaped details that differ from the PR path and must not be smoothed over: the flags
speak GitLab (`--source-branch`/`--target-branch`, not head/base), the number is GitLab's per-project
**iid**, and a project path may carry **nested subgroups** (`group/subgroup/project`) — relay it
verbatim rather than "correcting" it to an `owner/repo` shape.

If the user asked to **change** the title/description instead of approving, loop back to step 1;
re-expose; re-gate. Like the PR path, this one never runs G1.

---

## Termination

This flow does not auto-continue. When the approved operation(s) have landed, **stop**. A later "now
branch off", "now push it", "now tag a release", "now open the PR", or "now open the MR" is a **new invocation** with
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
- **Never let the git-operator default a new branch's base, the PR's base, or the MR's target
  branch, nor invent a new branch's ticket id** — each is an input from the delegation; ask if missing (Branch Path / Pull-Request Path /
  Merge-Request Path).
- **A branch write is plan → expose → consent → execute too, minus G1's commit preconditions** —
  `create-branch.sh` creates only, never checks out; never assume a just-created branch is what a
  later commit lands on (Branch Path).
