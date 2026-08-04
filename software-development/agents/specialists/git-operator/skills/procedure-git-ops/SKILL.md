---
name: procedure-git-ops
description: The procedure the git-operator runs to check readiness, branch, commit, push, and tag — the framework's most dangerous scripts, because they mutate git history and push it. It wraps five highly-portable, deterministic scripts — scripts/preflight.sh (READ-ONLY: work-tree/branch/in-progress-operation/dirty-file readiness check), scripts/create-branch.sh (idempotent `type/ticket-desc` branch creation, never checks out), scripts/commit.sh (commits the CURRENTLY-STAGED index from a message FILE, fail-closed on signature verification), scripts/push.sh (refuses a direct push to a protected branch outright, detects but never auto-resolves a non-fast-forward, idempotent no-op when already up to date), and scripts/create-tag.sh (signed annotated tag, refuses outright to re-tag/move a published version, fail-closed on verification). Every message (commit or tag) is ALWAYS a file, never built in a string/heredoc/$() — the same injection-safety rule as procedure-gh-issues/procedure-gh-pr. It does NOT define commit/branch/PR/tag CONVENTIONS (those are standard-git-commit/branch/pr/tag) or resolve/confirm the signing IDENTITY (procedure-git-identity — a separate, MANDATORY precondition the caller runs before commit.sh/create-tag.sh) — this skill only executes the git operation and verifies its result.
---

# Procedure: Git Operations (`git` wrapper scripts)

The **one** way the `git-operator` touches git history. This is a **procedure, not a rubric**: call the right script with the right flags; never hand-author a `git commit`/`git push`/`git tag` invocation, and never build a commit or tag message in shell. These are the framework's **most dangerous scripts** — they mutate history and push it — so every one of them **fails closed**: on doubt, on an unverifiable signature, on a protected branch, on a would-be duplicate, the answer is refuse and report, never guess or retry unsafely.

## Why these scripts exist (read this before calling anything)

A commit or tag message built via `-m "$msg"`/`-m "$(cat <<'EOF' … EOF)"` is the same **command-injection sink** `procedure-gh-issues` exists to eliminate for issue bodies — a message derived from a diff summary or a changelog can contain backticks/`$()`, and a heredoc built around it can be terminated early by a coincidental delimiter line. The fix is the same structural one: **the message is ALWAYS a file, passed via `-F <path>`.** `commit.sh` and `create-tag.sh` have no `-m`/`--message` passthrough at all.

The second load-bearing rule is **fail-closed on everything irreversible**: `commit.sh` verifies the commit it just made is actually signed (never retries with `--no-gpg-sign`); `create-tag.sh` verifies the tag it just made (never re-cuts a published version); `push.sh` refuses a protected branch outright and only ever detects — never resolves — a non-fast-forward. None of these scripts ever silently downgrades safety to make an operation succeed.

## The five scripts (`$HOME/.claude/skills/procedure-git-ops/scripts/` — all portable & deterministic)

**Invoke each by its deployed absolute path — `$HOME/.claude/skills/procedure-git-ops/scripts/<name>`.** Never a bare `scripts/<name>` (resolves against the repo cwd, where the script does not exist), and never `${CLAUDE_SKILL_DIR}/…` from an agent's Bash (that placeholder only resolves inside a skill's own `SKILL.md` content, not the calling agent's shell). All five are POSIX `sh`, run on any machine (macOS BSD / Bash 3.2 + Linux), `shellcheck`-clean, self-contained (no external library sourcing — small helpers are duplicated across scripts, not shared), and deterministic.

### `preflight.sh` — READ-ONLY

```
$HOME/.claude/skills/procedure-git-ops/scripts/preflight.sh --repo PATH \
  [--expect-branch NAME] [--expect-remote NAME] [-h|--help]
```

- Verifies: a real git work tree, HEAD on an actual branch (not detached), and no rebase/merge/cherry-pick already in progress — checked directly via the standard marker files/dirs (`rebase-merge`, `rebase-apply`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`), since git has no single query for "an operation is in progress." If `--expect-branch`/`--expect-remote` are given, reality must match.
- **Dirty files are reported, never themselves a readiness failure** — every dirty path is listed to stderr so the caller can see at a glance whether any of them are unrelated to what it's about to stage; a caller routinely runs this before staging anything at all.
- Prints `GITOP_CLEAN=`, `GITOP_BRANCH=`, `GITOP_DETACHED=`, `GITOP_OP_IN_PROGRESS=` (rebase/merge/cherry-pick/none), `GITOP_DIRTY_FILES=`.
- Exit `0` ready · `1` not ready (detached / an operation in progress / an `--expect-*` mismatch — reasons on stderr) · `2` usage error.

### `create-branch.sh`

```
$HOME/.claude/skills/procedure-git-ops/scripts/create-branch.sh --repo PATH \
  --type TYPE --ticket ID --desc SLUG --base BRANCH [-h|--help]
```

- Builds `TYPE/TICKET-DESC` and validates it against `standard-git-branch`'s naming convention (lowercase, hyphen-separated, no `#`, no spaces) before touching git at all.
- **Idempotent:** if the branch already exists, this is a no-op success — it does NOT re-create or error.
- **Creates ONLY — never checks the branch out.** The caller's current branch/working tree is untouched; switching to the new branch (if wanted) is a separate, explicit step outside this script's scope.
- Prints `GITOP_BRANCH=<name>`.
- Exit `0` branch exists (created or already did) · `1` `--base` doesn't resolve / `git branch` itself failed · `2` usage error (including a name that fails the naming convention).

### `commit.sh` — OUTWARD, IRREVERSIBLE, fail-closed on signing

```
$HOME/.claude/skills/procedure-git-ops/scripts/commit.sh --repo PATH \
  --message-file PATH [-h|--help]
```

- **Commits the CURRENTLY-STAGED index — it does NOT stage anything.** Staging is the atomic-split decision (`standard-git-commit` / the git-operator's judgment), not this script's job. If nothing is staged, this **fails** (exit `1`) rather than silently doing nothing.
- **The message is ALWAYS a file** (`-F`) — there is no `-m` passthrough, for the injection-safety reason above.
- Runs `git commit -S --signoff -F <message-file>`.
- **Fail-closed on signing:** after committing, checks `git log -1 --format=%G?` and accepts ONLY `G` (good) or `U` (good, unknown validity) — every other code (no signature, bad, expired, revoked, unverifiable) is a **failure**. It NEVER retries with `--no-gpg-sign`, and a failing hook is NEVER bypassed with `--no-verify`.
- **If the commit was created but then fails verification, `GITOP_COMMIT_SHA` is still printed** — this script does not auto-revert a bad commit (undoing history is a mutating decision outside its narrow scope), but it always gives the caller the identifier needed to inspect or undo it.
- Prints `GITOP_COMMIT_SHA=<sha>` whenever a commit object was actually created (including the failed-verification case above).
- Exit `0` committed and verified signed · `1` nothing staged / `git commit` itself failed / signature verification failed · `2` usage error.
- **NOT performed here:** staging, and identity resolution/confirmation (`procedure-git-identity` — run by the caller BEFORE this script).

### `push.sh` — OUTWARD, the most conditional

```
$HOME/.claude/skills/procedure-git-ops/scripts/push.sh --repo PATH \
  --remote NAME --branch NAME [--force-with-lease] [-h|--help]
```

- **Protected-branch refusal is unconditional and checked FIRST, before touching git at all:** `main`, `master`, `develop`, and any `release/*` branch NEVER get a direct push from this script — force or not. Those branches move only via a reviewed PR merge (`standard-git-branch`); `--force-with-lease` never overrides this.
- **First push vs. subsequent:** adds `-u` automatically when the branch has no upstream yet; otherwise a plain push.
- **Idempotent:** before pushing, compares the local branch's SHA against the remote's via `git ls-remote` — if they already match, this is a genuine no-op (the push is never even attempted) and still a success.
- **Non-fast-forward: DETECTED, never auto-resolved.** On a rejected push, this script recognizes git's non-ff rejection text and reports "non-fast-forward — rebase onto base then retry" — it never rebases or force-pushes on the caller's behalf; that judgment belongs to the calling agent.
- `--force-with-lease` uses git's own stale-check (never a bare `--force`), and only ever runs on a non-protected branch (the unconditional refusal above already guarantees this).
- Prints `GITOP_PUSHED=true|false` (false only on the idempotent no-op — both are success) and `GITOP_UPSTREAM=<remote>/<branch>`.
- Exit `0` pushed or already up to date · `1` protected branch / non-fast-forward / `git push` itself failed for another reason · `2` usage error.

### `create-tag.sh` — OUTWARD, IRREVERSIBLE, fail-closed on verification

```
$HOME/.claude/skills/procedure-git-ops/scripts/create-tag.sh --repo PATH \
  --version VER --sha SHA --message-file PATH [-h|--help]
```

- **Refuses outright to re-tag or move an already-published version** — if the tag name already exists, this **fails** (exit `1`); it never deletes, moves, or re-signs an existing tag (`standard-git-tag`: a released version is immutable).
- **The message is ALWAYS a file** (`-F`) — same injection-safety rule, no `-m` passthrough.
- Runs `git tag -s <version> <sha> -F <message-file>`, then **fail-closed verifies** with `git tag -v`. A verification failure is reported as a failure; the tag object is NOT auto-deleted (same reporting-not-reverting posture as `commit.sh`, for the same reason).
- `--version` must be **core SemVer** (`vX.Y.Z` or `X.Y.Z`, each component all-digits) — prerelease/build-metadata suffixes are deliberately out of scope for this validator (not asked for; the core shape is what every caller of this script actually produces).
- **Does NOT run the release-prep build** (`standard-git-tag`: that runs once, at the release boundary, before this script is even called) and does NOT decide what to release — only cuts and verifies the tag object once the caller has already decided the version and SHA.
- Prints `GITOP_TAG=<version>` on success.
- Exit `0` created and verified · `1` tag already exists / `--sha` doesn't resolve to a commit / `git tag` itself failed / verification failed · `2` usage error.

## The gates the CALLER (git-operator) must clear — NOT owned by this skill

This skill only executes the git operation and verifies its result; it never decides *whether* to act or *who* acts:

1. **The commit-plan gate** (`standard-git-commit`) — the split, the message(s), and the user's explicit approval of THIS commit, before `commit.sh` is ever called.
2. **The signing-identity gate** (`procedure-git-identity`) — committer email, signing key, and `Signed-off-by` all reconcile, confirmed by the user, before `commit.sh` or `create-tag.sh` is called. `commit.sh` assumes this already happened; it resolves nothing about identity itself.
3. **Whether to push at all** — the calling agent's judgment, informed by `preflight.sh`, before `push.sh` runs.
4. **Tag-consent** (`standard-git-tag`) — the exact version and target SHA, explicitly authorized by the user for THIS release, before `create-tag.sh` runs.

## Testing — two layers, proving different things

- **`tests/run-tests.sh`** (stub-driven, `sh`/`dash`-clean, no real git) — exercises the deterministic BRANCHING logic exhaustively and fast: protected-branch refusal, non-fast-forward detection, re-tag refusal, fail-closed signing checks (every `%G?` code), nothing-staged failure, idempotency, argument validation, exit codes.
- **`tests/smoke.sh`** (real `git` + a real, ephemeral, throwaway GPG key, generated fresh and deleted on exit — never the invoking user's real `~/.gnupg`, never a real repo, never the network) — proves the actual git/gpg CONTRACT the stub cannot: a real signed commit, a real push to a local bare remote, a real `--force-with-lease` against a rewritten local history, a real protected-branch refusal, a real non-fast-forward rejection, a real live-rebase op-in-progress block, a real re-tag refusal, a real signed tag + verify. If `gpg` is unavailable or ephemeral key generation fails, this script SKIPS the signing-dependent checks with a clear reason rather than failing the run — that is an environment constraint, not a defect.

**Run both before trusting a change to this skill.** The stub proves the logic; the smoke test proves the logic is checking the right thing in the first place — the class of gap that let the `close-issue --reason` enum bug ship once already.

**CI must gate on the signing-dependent checks actually having run, not merely on exit 0** — `tests/smoke.sh` prints a machine-readable `SMOKE_SIGNING=exercised` (gpg worked, the full signed-commit/signed-tag contract was proven) or `SMOKE_SIGNING=skipped` (no usable gpg in this environment) on stdout, in addition to its own `exit 0`/`exit 1`. An `exit 0` with `SMOKE_SIGNING=skipped` means the run is GREEN but PROVED NOTHING about signing — CI should assert `SMOKE_SIGNING=exercised`, not just a zero exit code, or a gpg-less runner could silently stop catching signing regressions.

## Constraints (NEVER violate)

- Never pass a commit or tag message as `-m`/a heredoc/a `$(...)` — it is ALWAYS a file via `-F`, full stop.
- Never retry a failed commit with `--no-gpg-sign`, and never bypass a failing hook with `--no-verify`.
- Never push directly to `main`/`master`/`develop`/`release/*` — force or not.
- Never auto-rebase or auto-force-push to resolve a non-fast-forward — detect and report only; the calling agent decides.
- Never re-tag, move, or re-sign an already-published version tag.
- Never resolve or confirm signing identity here — that is `procedure-git-identity`'s job, run by the caller first.
- Never commit into a detached HEAD or an in-progress rebase/merge/cherry-pick.
- Never run `tests/smoke.sh` against a real repository or without the isolated `GNUPGHOME` it sets up itself — it must always generate and use its own ephemeral key.

---
*Procedure Version: 1.0 — the git preflight/branch/commit/push/tag wrapper. Bound by the git-operator. Commit/branch/PR/tag CONVENTIONS live in standard-git-commit/branch/pr/tag; signing identity in procedure-git-identity — this skill only executes and verifies. Wraps `$HOME/.claude/skills/procedure-git-ops/scripts/`preflight.sh, create-branch.sh, commit.sh, push.sh, create-tag.sh — all portable POSIX, shellcheck-clean, self-contained.*
