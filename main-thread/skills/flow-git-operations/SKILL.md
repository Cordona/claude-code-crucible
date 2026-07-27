---
name: flow-git-operations
description: The orchestrator's on-demand procedure for a VCS / GIT-OPERATIONS request — the steps the primary agent runs when the user asks to commit, push, create a branch, or cut a release tag. Bind this skill when such a request fires ("commit", "commit that", "push", "branch off", "tag a release", "cut a release"), or when you are about to land changes you were asked to commit. It owns: briefing the git-operator to PLAN (read the diff, derive the atomic per-concern split un-framed by you, author each Conventional-Commit message to a file, resolve the signing identity, stage the hunks), exposing that plan (the full commit messages VERBATIM), CONSENT-GATING every commit / push / tag (the orchestrator executes only on the user's explicit in-turn approval), and EXECUTING the operation itself (the orchestrator writes; the operator only proposes — a subagent cannot verify that a relayed approval is genuine consent). It does NOT define commit/branch/tag CONVENTIONS (standard-git-commit / standard-git-branch / standard-git-tag), the git MECHANICS (procedure-git-ops scripts), the signing-identity gate (procedure-git-identity), or the GitHub-account gate (procedure-git-auth); it defines the orchestration procedure only. Pull requests are NOT VCS — a PR body is an authored, reviewer-audience artifact owned by the project-manager (flow-project-management / CLAUDE.md §6).
---

# Flow: Git Operations (on-demand)

The primary agent binds this skill **only when a VCS / git-operations request fires** — the git
counterpart of the project-manager's `flow-project-management`. The rest of the time it costs
nothing (it is not loaded). Its reason to exist: a commit is a permanent signed record and a push
is public, so the *how* — plan → expose → consent → execute — is procedure, and procedure lives in
a skill, not inlined in the operating contract.

**Trigger phrases:** "Commit" / "commit that" · "Push" · "Create a branch / branch off" · "Tag a
release / cut a release". *(A commit request is the single most common way unreviewed work ships —
"commit that" matches no build/review mode — so this skill also owns the consent + reviewed
preconditions below, not just the mechanics.)*

**What this skill owns vs. what it doesn't:**
- **Owns (here):** the plan-via-operator, exposure of the messages verbatim, the three permissions
  + the consent gate, and the orchestrator EXECUTING the operation.
- **Conventions** (commit format, branch naming, SemVer tags) → `standard-git-commit` /
  `standard-git-branch` / `standard-git-tag` (the git-operator builds to them).
- **Mechanics** (the deterministic scripts) → `procedure-git-ops`. **Signing identity** →
  `procedure-git-identity`. **GitHub account** → `procedure-git-auth`.
- **Pull requests are NOT here** — they are the project-manager's authored artifacts (CLAUDE.md §6 /
  `flow-project-management`). This skill lands commits, pushes branches, and cuts tags.

---

## Step G1 — The three permissions (confirm ALL THREE before anything — they are different)

1. **Consent** — the user explicitly asked for THIS commit/push/tag in this conversation. Neither a
   review nor an identity check can supply it. **If you are unsure whether they asked — they did
   not.** (The hard invariant below.)
2. **Reviewed** — changes **you** made that `git status` shows uncommitted have been through a
   review swarm (`flow-orchestration` §0). Pre-existing dirty work you did not author is not yours
   to gate on; say it is there and leave it alone.
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

**Collect the consent via `AskUserQuestion`** — the same structured gate the orchestration plan uses
(`flow-orchestration` §3). The full messages + identity stay in G3's live-markdown reveal *above* the
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
`standard-git-commit` + `procedure-git-identity` (+ `procedure-git-auth` for a push / any GitHub
operation) so the same gates apply. The `procedure-git-ops` scripts are deployed globally — invoke
them **by their deployed absolute path**; you need not be their bound owner.

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

## Termination

This flow does not auto-continue. When the approved operation(s) have landed, **stop**. A later "now
push it" or "now tag a release" is a **new invocation** with its own G1–G5 — never an automatic next
step. A new review pass your own push triggered is likewise a new invocation.

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

---
*Procedure Version: 1.0 — the on-demand VCS / git-operations workflow, extracted from CLAUDE.md §1's VCS block so the operating contract carries only the trigger + the invariant checklist. The git counterpart of `flow-project-management`. Conventions live in `standard-git-commit` / `-branch` / `-tag`; mechanics in `procedure-git-ops`; the signing identity in `procedure-git-identity`; the GitHub account in `procedure-git-auth`. Pull requests belong to the project-manager (CLAUDE.md §6). This skill is the orchestration procedure only.*
