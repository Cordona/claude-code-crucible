#!/usr/bin/env sh
#
# smoke.sh — REAL git + a REAL, EPHEMERAL, throwaway GPG identity, exercised
#            entirely inside an isolated work directory. This is the layer
#            tests/run-tests.sh's stub CANNOT provide: proof that the actual
#            git/gpg CONTRACT this suite assumes — `git commit -S` really
#            produces a commit `git log --format=%G?` calls 'G', a
#            non-fast-forward push really gets rejected with the text this
#            suite's grep pattern expects, `git tag -v` really verifies a
#            freshly signed tag — still holds against a real `git`/`gpg`,
#            not a hand-written stand-in for one. A stub can only be as
#              correct as its author's understanding of the real contract;
#            this script is what catches that understanding drifting from
#            reality (the exact class of bug that shipped once already: the
#            close-issue --reason enum not matching what gh actually
#            accepted).
#
# SAFETY (read before running): this script
#   * NEVER touches the invoking user's real ~/.gnupg — it generates a
#     throwaway GPG key inside a FRESH, EMPTY, ISOLATED $GNUPGHOME created
#     under a mktemp work dir, and every git/gpg command below runs with
#     THAT GNUPGHOME exported, never the ambient one.
#   * NEVER touches a real repository — it `git init`s a scratch working
#     repo AND a scratch BARE repo (the "remote") side by side, both inside
#     the same throwaway work dir.
#   * NEVER touches the network — the "remote" is a local bare repo on disk
#     (a plain path, not a URL), so every push in this script is a
#     filesystem operation, not a network one.
#   * Cleans up unconditionally on exit: kills the ephemeral gpg-agent
#     process bound to this GNUPGHOME (an orphaned agent holding a
#     soon-to-be-deleted homedir open is exactly the kind of leftover state
#     this script must not produce), then removes the entire work dir.
#   * If `gpg` is unavailable, or ephemeral key generation fails for any
#     reason, this script SKIPS the signing-dependent checks (reporting
#     exactly what was skipped and why) rather than failing the whole run —
#     an environment without a working gpg is a valid, reportable outcome,
#     not a defect in this suite.
#
# Usage: sh tests/smoke.sh    (or dash tests/smoke.sh)
# Exit 0 = everything that ran passed (including "everything was skipped
#          because gpg is unavailable" — that is reported, not a failure);
# Exit 1 = at least one exercised behavior did not match the real contract.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}
info()  { printf '%s: %s\n' "$PROG" "$*"; }
error() { printf '%s: error: %s\n' "$PROG" "$*" >&2; }

SCRIPTS_DIR=$(cd "$(dirname "$0")/../scripts" && pwd)
PREFLIGHT="$SCRIPTS_DIR/preflight.sh"
CREATEBRANCH="$SCRIPTS_DIR/create-branch.sh"
COMMIT="$SCRIPTS_DIR/commit.sh"
PUSH="$SCRIPTS_DIR/push.sh"
CREATETAG="$SCRIPTS_DIR/create-tag.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/git-ops-smoke.XXXXXX")
GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
export GNUPGHOME

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	GNUPGHOME="$GNUPGHOME" gpgconf --kill gpg-agent >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

TESTS_RUN=0
TESTS_FAIL=0
pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
section() { printf '\n== %s ==\n' "$1"; }

CUR_OUT=""
CUR_ERR=""
CUR_RC=0
run_real() {
	set +e
	"$@" >"$WORK/rout" 2>"$WORK/rerr"
	CUR_RC=$?
	set -e
	CUR_OUT=$(cat "$WORK/rout"); CUR_ERR=$(cat "$WORK/rerr")
	rm -f "$WORK/rout" "$WORK/rerr"
}

expect_rc() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_RC" -eq "$2" ]; then pass "$1"
	else fail "$1" "expected exit $2, got $CUR_RC; stderr: $CUR_ERR"; fi
}

# ---------------------------------------------------------------------------
# gpg availability — a missing gpg is a reportable SKIP, not a failure.
# ---------------------------------------------------------------------------
if ! command -v gpg >/dev/null 2>&1; then
	info "SKIPPED: gpg is not installed in this environment — the entire"
	info "signing-dependent smoke test (commit.sh, create-tag.sh, and the"
	info "parts of push.sh that depend on a signed commit existing) cannot"
	info "run. This is an environment constraint, not a defect; re-run on a"
	info "machine with gpg installed to exercise those paths for real."
	printf 'SMOKE_SIGNING=skipped\n'
	exit 0
fi

section "generating an ephemeral, throwaway GPG identity (isolated GNUPGHOME)"
cat >"$GNUPGHOME/gpg-agent.conf" <<'EOF'
allow-loopback-pinentry
EOF
cat >"$GNUPGHOME/gpg.conf" <<'EOF'
batch
no-tty
pinentry-mode loopback
EOF
chmod 600 "$GNUPGHOME/gpg-agent.conf" "$GNUPGHOME/gpg.conf"

KEY_PARAMS="$WORK/keyparams.txt"
cat >"$KEY_PARAMS" <<'EOF'
%no-protection
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: Git Ops Smoke Test
Name-Email: smoke-test@example.invalid
Expire-Date: 0
%commit
EOF

if ! gpg --batch --gen-key "$KEY_PARAMS" >"$WORK/keygen.log" 2>&1; then
	info "SKIPPED: ephemeral GPG key generation failed in this environment"
	info "(see below) — the signing-dependent smoke test cannot run. This is"
	info "an environment constraint (e.g. insufficient entropy, a locked-down"
	info "sandbox), not a defect in the scripts under test."
	sed 's/^/    /' "$WORK/keygen.log"
	printf 'SMOKE_SIGNING=skipped\n'
	exit 0
fi

FPR=$(gpg --batch --list-secret-keys --with-colons "smoke-test@example.invalid" \
	| awk -F: '/^fpr:/ { print $10; exit }')
if [ -z "$FPR" ]; then
	error "generated a key but could not resolve its fingerprint — aborting"
	exit 1
fi
info "ephemeral signing key: $FPR (this key and its GNUPGHOME are deleted on exit)"
printf 'SMOKE_SIGNING=exercised\n'

# ---------------------------------------------------------------------------
# A scratch working repo + a scratch BARE repo as its "remote" — both local
# filesystem paths under the same throwaway work dir. No network involved.
# ---------------------------------------------------------------------------
REMOTE_DIR="$WORK/remote.git"
REPO_DIR="$WORK/repo"
git init -q --bare "$REMOTE_DIR"
git init -q -b main "$REPO_DIR"
git -C "$REPO_DIR" config user.name "Git Ops Smoke Test"
git -C "$REPO_DIR" config user.email "smoke-test@example.invalid"
git -C "$REPO_DIR" config user.signingkey "$FPR"
git -C "$REPO_DIR" config gpg.format openpgp
git -C "$REPO_DIR" config commit.gpgsign true
git -C "$REPO_DIR" config tag.gpgSign true
git -C "$REPO_DIR" remote add origin "$REMOTE_DIR"

# ===========================================================================
# 1. preflight.sh + commit.sh: a REAL signed commit, cross-checked against
#    `git log --format=%G?` independently of the script's own exit code.
# ===========================================================================
section "commit.sh — a real signed commit on main"
printf 'hello\n' >"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt

run_real sh "$PREFLIGHT" --repo "$REPO_DIR"
expect_rc "preflight: ready on a fresh repo" 0

MSG1="$WORK/msg1.txt"
printf 'chore: seed the smoke-test repo\n\nInitial commit for the real-git smoke test.\n' >"$MSG1"
run_real sh "$COMMIT" --repo "$REPO_DIR" --message-file "$MSG1"
expect_rc "commit: real signed commit succeeds" 0
SHA1=$(printf '%s\n' "$CUR_OUT" | sed -n 's/^GITOP_COMMIT_SHA=//p')
if [ -n "$SHA1" ]; then pass "commit: GITOP_COMMIT_SHA was printed ($SHA1)"; else fail "commit: GITOP_COMMIT_SHA was printed" "stdout: $CUR_OUT"; fi

REAL_SIGN_STATUS=$(git -C "$REPO_DIR" log -1 --format=%G? "$SHA1" 2>/dev/null || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$REAL_SIGN_STATUS" = "G" ]; then pass "commit: independently re-verified as 'G' (good) via git log --format=%G?"
else fail "commit: independently re-verified as 'G'" "git reported: $REAL_SIGN_STATUS"; fi

# ===========================================================================
# 2. create-branch.sh + a second real signed commit on a feature branch.
# ===========================================================================
section "create-branch.sh — a real feature branch off main"
run_real sh "$CREATEBRANCH" --repo "$REPO_DIR" --type feat --ticket 1 --desc smoke-test --base main
expect_rc "create-branch: creates feat/1-smoke-test" 0
git -C "$REPO_DIR" checkout -q feat/1-smoke-test

printf 'hello again\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
MSG2="$WORK/msg2.txt"
printf 'feat: extend the smoke-test file\n' >"$MSG2"
run_real sh "$COMMIT" --repo "$REPO_DIR" --message-file "$MSG2"
expect_rc "commit: second real signed commit on the feature branch" 0
SHA2=$(printf '%s\n' "$CUR_OUT" | sed -n 's/^GITOP_COMMIT_SHA=//p')

# ===========================================================================
# 3. push.sh — a real first push to the local bare remote, idempotency, and
#    a real protected-branch refusal.
# ===========================================================================
section "push.sh — a real push to the local bare remote (no network)"
run_real sh "$PUSH" --repo "$REPO_DIR" --remote origin --branch feat/1-smoke-test
expect_rc "push: first push succeeds" 0
REMOTE_SHA=$(git ls-remote "$REMOTE_DIR" refs/heads/feat/1-smoke-test | awk '{print $1}')
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$REMOTE_SHA" = "$SHA2" ]; then pass "push: the pushed commit is really present on the bare remote"
else fail "push: the pushed commit is really present on the bare remote" "remote has: ${REMOTE_SHA:-<nothing>}, expected: $SHA2"; fi

run_real sh "$PUSH" --repo "$REPO_DIR" --remote origin --branch feat/1-smoke-test
expect_rc "push: second push is a real no-op (already up to date)" 0
if printf '%s\n' "$CUR_OUT" | grep -Fxq 'GITOP_PUSHED=false'; then pass "push: reported GITOP_PUSHED=false on the no-op"
else fail "push: reported GITOP_PUSHED=false on the no-op" "stdout: $CUR_OUT"; fi

# ===========================================================================
# 3b. push.sh --force-with-lease against REAL git: rewrite local history
#     (so the remote is legitimately behind), then force-push and prove via
#     `git ls-remote` — independently of the script's own exit code — that
#     the remote ref actually moved to the amended SHA. This MUST run before
#     the non-fast-forward section below, which deliberately makes the local
#     repo's view of the remote stale; running force-with-lease after that
#     would fail for the wrong reason (a stale lease), not prove the real
#     force path.
# ===========================================================================
section "push.sh — a real --force-with-lease against the local bare remote"
printf 'an amended addition\n' >>"$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -q --amend --no-gpg-sign -m "feat: extend the smoke-test file (amended)"
SHA2_AMENDED=$(git -C "$REPO_DIR" rev-parse HEAD)
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$SHA2_AMENDED" != "$SHA2" ]; then pass "force-with-lease: local history was really rewritten to a new SHA"
else fail "force-with-lease: local history was really rewritten to a new SHA" "amend produced the same SHA: $SHA2_AMENDED"; fi

run_real sh "$PUSH" --repo "$REPO_DIR" --remote origin --branch feat/1-smoke-test --force-with-lease
expect_rc "force-with-lease: push succeeds against real git" 0
REMOTE_SHA_AFTER_LEASE=$(git ls-remote "$REMOTE_DIR" refs/heads/feat/1-smoke-test | awk '{print $1}')
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$REMOTE_SHA_AFTER_LEASE" = "$SHA2_AMENDED" ]; then
	pass "force-with-lease: the remote ref genuinely moved to the amended SHA"
else
	fail "force-with-lease: the remote ref genuinely moved to the amended SHA" "remote has: ${REMOTE_SHA_AFTER_LEASE:-<nothing>}, expected: $SHA2_AMENDED"
fi
SHA2="$SHA2_AMENDED"

run_real sh "$PUSH" --repo "$REPO_DIR" --remote origin --branch main
expect_rc "push: refuses a direct push to main for real" 1
MAIN_ON_REMOTE=$(git ls-remote "$REMOTE_DIR" refs/heads/main | awk '{print $1}')
TESTS_RUN=$((TESTS_RUN + 1))
if [ -z "$MAIN_ON_REMOTE" ]; then pass "push: main was genuinely never pushed to the remote"
else fail "push: main was genuinely never pushed to the remote" "remote unexpectedly has main: $MAIN_ON_REMOTE"; fi

# ===========================================================================
# 4. A real non-fast-forward rejection: a second clone pushes first, then
#    the original (now-stale) repo's push is rejected by the real remote.
# ===========================================================================
section "push.sh — a real non-fast-forward rejection"
OTHER_DIR="$WORK/other"
git clone -q "$REMOTE_DIR" "$OTHER_DIR"
git -C "$OTHER_DIR" config user.name "Other Clone"
git -C "$OTHER_DIR" config user.email "other@example.invalid"
git -C "$OTHER_DIR" checkout -q feat/1-smoke-test
printf 'a change from elsewhere\n' >>"$OTHER_DIR/file.txt"
git -C "$OTHER_DIR" commit -q --no-gpg-sign -am "a conflicting change from another clone"
git -C "$OTHER_DIR" push -q origin feat/1-smoke-test

run_real sh "$PUSH" --repo "$REPO_DIR" --remote origin --branch feat/1-smoke-test
expect_rc "push: the now-stale local branch is rejected" 1
if printf '%s\n' "$CUR_ERR" | grep -Fq 'non-fast-forward — rebase onto base then retry'; then
	pass "push: a REAL non-fast-forward rejection was correctly diagnosed"
else
	fail "push: a REAL non-fast-forward rejection was correctly diagnosed" "stderr: $CUR_ERR"
fi

# ===========================================================================
# 4b. preflight.sh — a REAL, live, mid-conflict rebase, proving the
#     op-in-progress detection against actual `.git/rebase-merge` state
#     rather than the stub's hand-set env var. Self-contained: uses its own
#     throwaway branch off main, and cleans up (rebase --abort + branch -D)
#     before the create-tag.sh section below.
# ===========================================================================
section "preflight.sh — REAL op-in-progress detection (a live, mid-conflict rebase)"
git -C "$REPO_DIR" checkout -q main
git -C "$REPO_DIR" checkout -q -b rebase-conflict-test
printf 'conflicting line from rebase-conflict-test\n' >"$REPO_DIR/conflict.txt"
git -C "$REPO_DIR" add conflict.txt
git -C "$REPO_DIR" commit -q --no-gpg-sign -m "conflicting change on rebase-conflict-test"
git -C "$REPO_DIR" checkout -q main
printf 'a different conflicting line from main\n' >"$REPO_DIR/conflict.txt"
git -C "$REPO_DIR" add conflict.txt
git -C "$REPO_DIR" commit -q --no-gpg-sign -m "a different conflicting change on main"
git -C "$REPO_DIR" checkout -q rebase-conflict-test

set +e
git -C "$REPO_DIR" rebase main >"$WORK/rebase.log" 2>&1
REBASE_RC=$?
set -e
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$REBASE_RC" -ne 0 ]; then
	pass "preflight setup: the rebase genuinely conflicted and stopped mid-way"
else
	fail "preflight setup: the rebase genuinely conflicted and stopped mid-way" "rebase unexpectedly succeeded (see $WORK/rebase.log)"
	git -C "$REPO_DIR" rebase --abort >/dev/null 2>&1 || true
fi

run_real sh "$PREFLIGHT" --repo "$REPO_DIR"
expect_rc "preflight: blocks while a real rebase is in progress" 1
if printf '%s\n' "$CUR_OUT" | grep -Fxq 'GITOP_OP_IN_PROGRESS=rebase'; then
	pass "preflight: reported GITOP_OP_IN_PROGRESS=rebase for a real, live rebase conflict"
else
	fail "preflight: reported GITOP_OP_IN_PROGRESS=rebase for a real, live rebase conflict" "stdout: $CUR_OUT"
fi

git -C "$REPO_DIR" rebase --abort
git -C "$REPO_DIR" checkout -q main
git -C "$REPO_DIR" branch -q -D rebase-conflict-test

# ===========================================================================
# 5. create-tag.sh — a real signed tag, independently re-verified, and a
#    real refusal to re-tag.
# ===========================================================================
section "create-tag.sh — a real signed tag"
TAGMSG="$WORK/tagmsg.txt"
printf 'Release v0.1.0\n\nSmoke-test release.\n' >"$TAGMSG"
run_real sh "$CREATETAG" --repo "$REPO_DIR" --version v0.1.0 --sha "$SHA1" --message-file "$TAGMSG"
expect_rc "create-tag: a real signed tag is created" 0

TESTS_RUN=$((TESTS_RUN + 1))
if git -C "$REPO_DIR" tag -v v0.1.0 >/dev/null 2>&1; then
	pass "create-tag: independently re-verified via a SEPARATE git tag -v call"
else
	fail "create-tag: independently re-verified via a SEPARATE git tag -v call" "git tag -v failed"
fi

run_real sh "$CREATETAG" --repo "$REPO_DIR" --version v0.1.0 --sha "$SHA2" --message-file "$TAGMSG"
expect_rc "create-tag: refuses to re-tag/move v0.1.0 for real" 1
POINTS_AT=$(git -C "$REPO_DIR" rev-list -n 1 v0.1.0)
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$POINTS_AT" = "$SHA1" ]; then pass "create-tag: v0.1.0 genuinely still points at the original commit"
else fail "create-tag: v0.1.0 genuinely still points at the original commit" "now points at: $POINTS_AT"; fi

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== smoke summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL SMOKE CHECKS PASSED (real git + a real, now-deleted, ephemeral GPG key)\n'
exit 0
